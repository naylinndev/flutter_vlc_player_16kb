package software.solid.fluttervlcplayer;

import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.View;

import androidx.annotation.Nullable;

import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.RendererDiscoverer;
import org.videolan.libvlc.RendererItem;
import org.videolan.libvlc.interfaces.IMedia;
import java.util.Random;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicInteger;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.view.TextureRegistry;
import software.solid.fluttervlcplayer.Enums.HwAcc;

/**
 * libVLC's MediaPlayer.stop() and release() wait for the player's input
 * thread to exit. With a stalled network stream that can take minutes or
 * never happen, so calling them on the main thread caused ANRs. Every call
 * that changes the playback state therefore runs on {@link #worker}, one
 * thread per player, in the order Dart issued them. A stalled stop only blocks
 * its own player's worker.
 *
 * <p>The main thread attaches/detaches the views, forwards events and answers
 * the synchronous getters. While a stop or release is pending the getters do
 * not call into libVLC (they could block too) and return the same "unknown"
 * values as for a missing player.
 *
 * <p>A stop or release that has not returned after {@link #STOP_WARNING_MS} is
 * logged (see {@link #runStop}). libVLC can block there for good, e.g. when
 * the hardware decoder never delivers a first picture; that player's threads
 * then stay alive, but the app keeps running.
 */
final class FlutterVlcPlayer implements PlatformView {

    // A libVLC stop/release still running after this long is logged.
    private static final long STOP_WARNING_MS = 5000;
    private final String TAG = this.getClass().getSimpleName();
    private final boolean debug = false;
    private final int viewId;
    //
    private final Context context;
    private final VLCTextureView textureView;
    private final TextureRegistry.SurfaceTextureEntry textureEntry;
    //
    private final QueuingEventSink mediaEventSink = new QueuingEventSink();
    private final EventChannel mediaEventChannel;
    //
    private final QueuingEventSink rendererEventSink = new QueuingEventSink();
    private final EventChannel rendererEventChannel;
    //
    private final ExecutorService worker;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    // Number of stop/release calls queued or running on the worker.
    private final AtomicInteger pendingStops = new AtomicInteger();
    //
    private LibVLC libVLC;
    private MediaPlayer mediaPlayer;
    private List<String> options;
    private List<RendererDiscoverer> rendererDiscoverers = new ArrayList<>();
    private List<RendererItem> rendererItems = new ArrayList<>();
    // Volatile: also read by worker tasks.
    private volatile boolean isDisposed = false;
    // Position of the last timeChanged event, sent with "ended" when the
    // getters can't be used (see queryable()).
    private long lastPosition = 0;

    // Platform view
    @Override
    public View getView() {
        return textureView;
    }

    @Override
    public void dispose() {
        if (isDisposed)
            return;
        isDisposed = true;
        final MediaPlayer mp = mediaPlayer;
        final LibVLC vlc = libVLC;
        mediaPlayer = null;
        libVLC = null;
        //
        mediaEventChannel.setStreamHandler(null);
        rendererEventChannel.setStreamHandler(null);
        if (mp != null) {
            mp.setEventListener(null);
            mp.getVLCVout().detachViews();
        }
        textureView.dispose();
        textureEntry.release();
        //
        // Queued behind any pending stop/setStreamUrl of this player; may take
        // long if the stream is stalled.
        pendingStops.incrementAndGet();
        enqueue(() -> {
            try {
                runStop("release", () -> {
                    if (mp != null) {
                        mp.stop();
                        mp.release();
                    }
                    if (vlc != null)
                        vlc.release();
                });
            } finally {
                pendingStops.decrementAndGet();
            }
        }, null, true);
        worker.shutdown();
    }

    // VLC Player
    FlutterVlcPlayer(int viewId, Context context, BinaryMessenger binaryMessenger, TextureRegistry textureRegistry) {
        this.context = context;
        this.viewId = viewId;
        worker = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, "VlcPlayerWorker-" + viewId);
            thread.setDaemon(true);
            return thread;
        });
        // event for media
        mediaEventChannel = new EventChannel(binaryMessenger, "flutter_video_plugin/getVideoEvents_" + viewId);
        mediaEventChannel.setStreamHandler(
                new EventChannel.StreamHandler() {
                    @Override
                    public void onListen(Object o, EventChannel.EventSink sink) {
                        mediaEventSink.setDelegate(sink);
                    }

                    @Override
                    public void onCancel(Object o) {
                        mediaEventSink.setDelegate(null);
                    }
                });
        // event for renderer
        rendererEventChannel = new EventChannel(binaryMessenger, "flutter_video_plugin/getRendererEvents_" + viewId);
        rendererEventChannel.setStreamHandler(
                new EventChannel.StreamHandler() {
                    @Override
                    public void onListen(Object o, EventChannel.EventSink sink) {
                        rendererEventSink.setDelegate(sink);
                    }

                    @Override
                    public void onCancel(Object o) {
                        rendererEventSink.setDelegate(null);
                    }
                });
        //
        textureEntry = textureRegistry.createSurfaceTexture();
        textureView = new VLCTextureView(context);
        textureView.setSurfaceTexture(textureEntry.surfaceTexture());
        textureView.forceLayout();
        textureView.setFitsSystemWindows(true);
        // Resuming after the surface comes back must stay in order with the
        // other calls.
        textureView.setResumePlayback(this::play);
    }

    /**
     * Runs task on the worker. result (may be null) is completed on the main
     * thread afterwards, also when the task was skipped. Tasks of a disposed
     * player are skipped unless runWhenDisposed.
     */
    private void enqueue(Runnable task, @Nullable Messages.Result<Void> result, boolean runWhenDisposed) {
        try {
            worker.execute(() -> {
                Throwable error = null;
                try {
                    if (runWhenDisposed || !isDisposed)
                        task.run();
                } catch (Throwable t) {
                    // An exception must not kill the worker (or the app).
                    // Class only: the message can contain the media URL.
                    Log.e(TAG, "libVLC call failed: " + t.getClass().getName());
                    error = t;
                }
                if (result != null) {
                    final Throwable failure = error;
                    mainHandler.post(() -> {
                        if (failure == null)
                            result.success(null);
                        else
                            result.error(failure);
                    });
                }
            });
        } catch (RejectedExecutionException e) {
            // Worker already shut down: the player was disposed.
            if (result != null)
                mainHandler.post(() -> result.success(null));
        }
    }

    /** Runs task on the worker with the current MediaPlayer, if any. */
    private void enqueue(PlayerTask task) {
        final MediaPlayer mp = mediaPlayer;
        if (mp == null || isDisposed)
            return;
        enqueue(() -> task.run(mp), null, false);
    }

    private interface PlayerTask {
        void run(MediaPlayer mp);
    }

    /**
     * The player for a synchronous getter on the main thread, or null while
     * it must not be called: disposed, or a stop/release is still pending.
     */
    @Nullable
    private MediaPlayer queryable() {
        if (isDisposed || pendingStops.get() > 0)
            return null;
        return mediaPlayer;
    }

    public void initialize(List<String> options) {
        this.options = options;
        libVLC = new LibVLC(context, options);
        mediaPlayer = new MediaPlayer(libVLC);
        setupVlcMediaPlayer();
    }

    private void setupVlcMediaPlayer() {

        //
        mediaPlayer.getVLCVout().setWindowSize(textureView.getWidth(), textureView.getHeight());
        mediaPlayer.getVLCVout().setVideoSurface(textureView.getSurfaceTexture());
        textureView.setTextureEntry(textureEntry);
        textureView.setMediaPlayer(mediaPlayer);
        mediaPlayer.setVideoTrackEnabled(true);
        //
        mediaPlayer.setEventListener(
                new MediaPlayer.EventListener() {
                    @Override
                    public void onEvent(MediaPlayer.Event event) {
                        if (isDisposed)
                            return;
                        // Null while a stop/release is pending: the events then
                        // belong to the media being stopped, and the ones that
                        // need getters are dropped.
                        final MediaPlayer mp = queryable();
                        HashMap<String, Object> eventObject = new HashMap<>();
                        //
                        // Get video dimensions from texture view as fallback
                        int height = textureView.getHeight();
                        int width = textureView.getWidth();
                        //
                        switch (event.type) {

                            case MediaPlayer.Event.Opening:
                                eventObject.put("event", "opening");
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.Paused:
                                eventObject.put("event", "paused");
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.Stopped:
                                eventObject.put("event", "stopped");
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.Playing:
                                if (mp == null)
                                    break;
                                eventObject.put("event", "playing");
                                eventObject.put("height", height);
                                eventObject.put("width", width);
                                eventObject.put("speed", mp.getRate());
                                eventObject.put("duration", mp.getLength());
                                eventObject.put("audioTracksCount", getAudioTracksCount());
                                eventObject.put("activeAudioTrack", getAudioTrack());
                                eventObject.put("spuTracksCount", getSpuTracksCount());
                                eventObject.put("activeSpuTrack", getSpuTrack());
                                mediaEventSink.success(eventObject.clone());
                                break;

                            case MediaPlayer.Event.Vout:
                                break;

                            case MediaPlayer.Event.EndReached:
                                eventObject.put("event", "ended");
                                eventObject.put("position", mp != null ? mp.getTime() : lastPosition);
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.Buffering:
                            case MediaPlayer.Event.TimeChanged:
                                if (mp == null)
                                    break;
                                lastPosition = mp.getTime();
                                eventObject.put("event", "timeChanged");
                                eventObject.put("height", height);
                                eventObject.put("width", width);
                                eventObject.put("speed", mp.getRate());
                                eventObject.put("position", lastPosition);
                                eventObject.put("duration", mp.getLength());
                                eventObject.put("buffer", event.getBuffering());
                                eventObject.put("audioTracksCount", getAudioTracksCount());
                                eventObject.put("activeAudioTrack", getAudioTrack());
                                eventObject.put("spuTracksCount", getSpuTracksCount());
                                eventObject.put("activeSpuTrack", getSpuTrack());
                                eventObject.put("isPlaying", mp.isPlaying());
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.EncounteredError:
                                eventObject.put("event", "error");
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.RecordChanged:
                                eventObject.put("event", "recording");
                                eventObject.put("isRecording", event.getRecording());
                                eventObject.put("recordPath", event.getRecordPath());
                                mediaEventSink.success(eventObject);
                                break;

                            case MediaPlayer.Event.LengthChanged:
                            case MediaPlayer.Event.MediaChanged:
                            case MediaPlayer.Event.ESAdded:
                            case MediaPlayer.Event.ESDeleted:
                            case MediaPlayer.Event.ESSelected:
                            case MediaPlayer.Event.PausableChanged:
                            case MediaPlayer.Event.SeekableChanged:
                            case MediaPlayer.Event.PositionChanged:
                            default:
                                break;
                        }
                    }
                }
        );
    }

    void play() {
        enqueue(mp -> {
            if (!mp.isPlaying())
                mp.play();
        });
    }

    void pause() {
        enqueue(mp -> {
            if (mp.isPlaying())
                mp.pause();
        });
    }

    /** Completes result on the main thread once libVLC has stopped (or the stop was skipped). */
    void stop(Messages.Result<Void> result) {
        final MediaPlayer mp = mediaPlayer;
        if (mp == null || isDisposed) {
            result.success(null);
            return;
        }
        pendingStops.incrementAndGet();
        enqueue(() -> {
            try {
                if (!isDisposed)
                    runStop("stop", mp::stop);
            } finally {
                pendingStops.decrementAndGet();
            }
        }, result, true);
    }

    boolean isPlaying() {
        MediaPlayer mp = queryable();
        if (mp == null) return false;
        return mp.isPlaying();
    }

    boolean isSeekable() {
        MediaPlayer mp = queryable();
        if (mp == null) return false;
        return mp.isSeekable();
    }

    /** Completes result on the main thread once the media is set (or the call was skipped). */
    void setStreamUrl(String url, boolean isAssetUrl, boolean autoPlay, long hwAcc, Messages.Result<Void> result) {
        final MediaPlayer mp = mediaPlayer;
        final LibVLC vlc = libVLC;
        if (mp == null || vlc == null || isDisposed) {
            result.success(null);
            return;
        }
        lastPosition = 0;
        final List<String> mediaOptions = options;
        enqueue(() -> {
            try {
                if (mp.isPlaying()) {
                    pendingStops.incrementAndGet();
                    try {
                        runStop("stop", mp::stop);
                    } finally {
                        pendingStops.decrementAndGet();
                    }
                }
                if (isDisposed)
                    return;
                //
                Media media;
                if (isAssetUrl)
                    media = new Media(vlc, context.getAssets().openFd(url));
                else if (url.startsWith("content://"))
                    media = new Media(vlc, context.getContentResolver().openFileDescriptor(Uri.parse(url), "r").getFileDescriptor());
                else
                    media = new Media(vlc, Uri.parse(url));
                final HwAcc hwAccValue = HwAcc.values()[(int) hwAcc];
                switch (hwAccValue) {
                    case DISABLED:
                        media.setHWDecoderEnabled(false, false);
                        break;
                    case DECODING:
                    case FULL:
                        media.setHWDecoderEnabled(true, true);
                        break;
                }
                if (hwAccValue == HwAcc.DECODING) {
                    media.addOption(":no-mediacodec-dr");
                    media.addOption(":no-omxil-dr");
                }
                if (mediaOptions != null) {
                    for (String option : mediaOptions)
                        media.addOption(option);
                }
                mp.setMedia(media);
                media.release();
                //
                if (autoPlay) {
                    mp.play();
                }
            } catch (IOException e) {
                log(e.getMessage());
            }
        }, result, false);
    }

    void setLooping(boolean value) {
        enqueue(mp -> {
            if (mp.getMedia() != null)
                mp.getMedia().addOption(value ? "--loop" : "--no-loop");
        });
    }

    void setVolume(long value) {
        long bracketedValue = Math.max(0, Math.min(100, value));
        enqueue(mp -> mp.setVolume((int) bracketedValue));
    }

    int getVolume() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        return mp.getVolume();
    }

    void setPlaybackSpeed(double value) {
        enqueue(mp -> mp.setRate((float) value));
    }

    float getPlaybackSpeed() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1.0f;

        return mp.getRate();
    }

    void seekTo(long location) {
        enqueue(mp -> mp.setTime(location));
    }

    long getPosition() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        return mp.getTime();
    }

    long getDuration() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        return mp.getLength();
    }

    int getSpuTracksCount() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track[] spuTracks = mp.getTracks(IMedia.Track.Type.Text);
        return spuTracks != null ? spuTracks.length : 0;
    }

    HashMap<Integer, String> getSpuTracks() {
        MediaPlayer mp = queryable();
        if (mp == null) return new HashMap<Integer, String>();

        IMedia.Track[] spuTracks = mp.getTracks(IMedia.Track.Type.Text);
        HashMap<Integer, String> subtitles = new HashMap<>();
        if (spuTracks != null)
            for (IMedia.Track trackDescription : spuTracks) {
                subtitles.put(Integer.parseInt(trackDescription.id.replaceAll("\\D", "")), trackDescription.name);
            }
        return subtitles;
    }

    void setSpuTrack(int index) {
        enqueue(mp -> {
            try {
                if (index >= 0) {
                    // Select the track by its ID
                    mp.selectTrack("spu/" + index);
                } else if (index == -1) {
                    // Unselect all text tracks
                    mp.unselectTrackType(IMedia.Track.Type.Text);
                }
            } catch (Exception e) {
                Log.e(TAG, "setAudioTrack failed: " + e.getMessage());
            }
        });
    }

    int getSpuTrack() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track track = mp.getSelectedTrack(IMedia.Track.Type.Text);
        if(track == null) {
            return -1;
        }
        return Integer.parseInt(track.id.replaceAll("\\D", ""));
    }

    void setSpuDelay(long delay) {
        enqueue(mp -> mp.setSpuDelay(delay));
    }

    long getSpuDelay() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        return mp.getSpuDelay();
    }

    void addSubtitleTrack(String url, boolean isSelected) {
        enqueue(mp -> mp.addSlave(Media.Slave.Type.Subtitle, Uri.parse(url), isSelected));
    }

    int getAudioTracksCount() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track[] audioTracks = mp.getTracks(IMedia.Track.Type.Audio);
        return audioTracks != null ? audioTracks.length : 0;
    }

    HashMap<Integer, String> getAudioTracks() {
        MediaPlayer mp = queryable();
        if (mp == null) return new HashMap<Integer, String>();

        IMedia.Track[] audioTracks = mp.getTracks(IMedia.Track.Type.Audio);
        HashMap<Integer, String> audios = new HashMap<>();
        Random random = new Random();
        if (audioTracks != null)
            for (IMedia.Track trackDescription : audioTracks) {
                    audios.put(Integer.parseInt(trackDescription.id.replaceAll("\\D", "")), trackDescription.name);
            }
        return audios;
    }

    void setAudioTrack(int index) {
        enqueue(mp -> {
            try {
                if (index >= 0) {
                    // Select the track by its ID
                    mp.selectTrack("audio/" + index);
                } else if (index == -1) {
                    // Unselect all audio tracks
                    mp.unselectTrackType(IMedia.Track.Type.Audio);
                }
            } catch (Exception e) {
                Log.e(TAG, "setAudioTrack failed: " + e.getMessage());
            }
        });
    }

    int getAudioTrack() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track track = mp.getSelectedTrack(IMedia.Track.Type.Audio);
        if(track == null) {
            return -1;
        }
        return Integer.parseInt(track.id.replaceAll("\\D", ""));
    }

    void setAudioDelay(long delay) {
        enqueue(mp -> mp.setAudioDelay(delay));
    }

    long getAudioDelay() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        return mp.getAudioDelay();
    }

    void addAudioTrack(String url, boolean isSelected) {
        enqueue(mp -> mp.addSlave(Media.Slave.Type.Audio, Uri.parse(url), isSelected));
    }

    int getVideoTracksCount() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track[] videoTracks = mp.getTracks(IMedia.Track.Type.Video);
        return videoTracks != null ? videoTracks.length : 0;

    }

    HashMap<Integer, String> getVideoTracks() {
        MediaPlayer mp = queryable();
        if (mp == null) return new HashMap<Integer, String>();

        IMedia.Track[] videoTracks = mp.getTracks(IMedia.Track.Type.Video);
        HashMap<Integer, String> videos = new HashMap<>();
        if (videoTracks != null)
            for (IMedia.Track trackDescription : videoTracks) {
                    videos.put(Integer.parseInt(trackDescription.id.replaceAll("\\D", "")), trackDescription.name);
            }
        return videos;
    }

    void setVideoTrack(int index) {
        enqueue(mp -> {
            try {
                if (index >= 0) {
                    // Select the track by its ID
                    mp.selectTrack("video/" + index);
                } else if (index == -1) {
                    // Unselect all video tracks
                    mp.unselectTrackType(IMedia.Track.Type.Video);
                }
            } catch (Exception e) {
                Log.e(TAG, "setAudioTrack failed: " + e.getMessage());
            }
        });
    }

    int getVideoTrack() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1;

        IMedia.Track track = mp.getSelectedTrack(IMedia.Track.Type.Video);
        if(track == null) {
            return -1;
        }
        return Integer.parseInt(track.id.replaceAll("\\D", ""));

    }

    void setVideoScale(float scale) {
        enqueue(mp -> mp.setScale(scale));
    }

    float getVideoScale() {
        MediaPlayer mp = queryable();
        if (mp == null) return -1.0f;

        return mp.getScale();
    }

    void setVideoAspectRatio(String aspectRatio) {
        enqueue(mp -> mp.setAspectRatio(aspectRatio));
    }

    String getVideoAspectRatio() {
        MediaPlayer mp = queryable();
        if (mp == null) return "";

        return mp.getAspectRatio();
    }

    void startRendererScanning(String rendererService) {
        if (libVLC == null) return;

        rendererDiscoverers = new ArrayList<>();
        rendererItems = new ArrayList<>();
        //
        RendererDiscoverer.Description[] renderers = RendererDiscoverer.list(libVLC);
        for (RendererDiscoverer.Description renderer : renderers) {
            RendererDiscoverer rendererDiscoverer = new RendererDiscoverer(libVLC, renderer.name);
            try {
                rendererDiscoverer.setEventListener(new RendererDiscoverer.EventListener() {
                    @Override
                    public void onEvent(RendererDiscoverer.Event event) {
                        HashMap<String, Object> eventObject = new HashMap<>();
                        RendererItem item = event.getItem();
                        switch (event.type) {
                            case RendererDiscoverer.Event.ItemAdded:
                                rendererItems.add(item);
                                eventObject.put("event", "attached");
                                eventObject.put("id", item.name);
                                eventObject.put("name", item.displayName);
                                rendererEventSink.success(eventObject);
                                break;

                            case RendererDiscoverer.Event.ItemDeleted:
                                rendererItems.remove(item);
                                eventObject.put("event", "detached");
                                eventObject.put("id", item.name);
                                eventObject.put("name", item.displayName);
                                rendererEventSink.success(eventObject);
                                break;

                            default:
                                break;
                        }
                    }
                });
                rendererDiscoverer.start();
                rendererDiscoverers.add(rendererDiscoverer);
            } catch (Exception ex) {
                rendererDiscoverer.setEventListener(null);
            }
        }
    }

    void stopRendererScanning() {
        if (mediaPlayer == null) return;

        if (isDisposed)
            return;
        //
        for (RendererDiscoverer rendererDiscoverer : rendererDiscoverers) {
            rendererDiscoverer.stop();
            rendererDiscoverer.setEventListener(null);
        }
        rendererDiscoverers.clear();
        rendererItems.clear();
        //
        enqueue(mp -> {
            mp.pause();
            mp.setRenderer(null);
            mp.play();
        });
    }

    ArrayList<String> getAvailableRendererServices() {
        if (libVLC == null) return new ArrayList<String>();

        RendererDiscoverer.Description[] renderers = RendererDiscoverer.list(libVLC);
        ArrayList<String> availableRendererServices = new ArrayList<>();
        for (RendererDiscoverer.Description renderer : renderers) {
            availableRendererServices.add(renderer.name);
        }
        return availableRendererServices;
    }

    HashMap<String, String> getRendererDevices() {
        HashMap<String, String> renderers = new HashMap<>();
        if (rendererItems != null)
            for (RendererItem rendererItem : rendererItems) {
                renderers.put(rendererItem.name, rendererItem.displayName);
            }
        return renderers;
    }

    void castToRenderer(String rendererDevice) {
        if (mediaPlayer == null) return;

        if (isDisposed) {
            return;
        }

        RendererItem rendererItem = null;
        for (RendererItem item : rendererItems) {
            if (item.name.equals(rendererDevice)) {
                rendererItem = item;
                break;
            }
        }
        final RendererItem selected = rendererItem;
        enqueue(mp -> {
            if (mp.isPlaying())
                mp.pause();
            mp.setRenderer(selected);
            mp.play();
        });
    }

    @Nullable
    String getSnapshot() {
        if (textureView == null) return null;
        MediaPlayer mp = queryable();
        if (mp == null) return null;
        if (!mp.isPlaying()) return null;
        Bitmap bitmap = textureView.getBitmap();
        if (bitmap == null) return null;

        ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream);
        return Base64.encodeToString(outputStream.toByteArray(), Base64.NO_WRAP);
    }

    Boolean startRecording(String directory) {
        MediaPlayer mp = queryable();
        if (mp == null) return false;
        return mp.record(directory, false);
    }

    Boolean stopRecording() {
        MediaPlayer mp = queryable();
        if (mp == null) return true;
        return mp.record(null, false);
    }

    /**
     * Runs a libVLC stop/release call on the worker and logs a warning if it
     * has not returned after STOP_WARNING_MS, and again if it returns later.
     */
    private void runStop(String name, Runnable call) {
        final long start = System.nanoTime();
        // 0: running, 1: returned in time, 2: reported as not returned
        final AtomicInteger state = new AtomicInteger();
        final Runnable warning = () -> {
            if (state.compareAndSet(0, 2))
                Log.w(TAG, "libVLC " + name + " of player " + viewId + " has not returned after " + STOP_WARNING_MS + " ms");
        };
        mainHandler.postDelayed(warning, STOP_WARNING_MS);
        try {
            call.run();
        } finally {
            mainHandler.removeCallbacks(warning);
            if (!state.compareAndSet(0, 1))
                Log.w(TAG, "libVLC " + name + " of player " + viewId + " returned after " + (System.nanoTime() - start) / 1000000 + " ms");
        }
    }

    private void log(String message) {
        if (debug) {
            Log.d(TAG, message);
        }
    }
}