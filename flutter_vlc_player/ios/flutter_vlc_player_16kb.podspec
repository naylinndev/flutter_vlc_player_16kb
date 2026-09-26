#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_vlc_player.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_vlc_player_16kb'
  s.version          = '3.0.3'
  s.summary          = 'VLC-powered video player for Flutter (16kb page size fix).'
  s.description      = 'Supports multiple players on one screen.'
  s.homepage         = 'https://github.com/solid-software/flutter_vlc_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }

  # Include all source files
  s.source_files = 'flutter_vlc_player_16kb/Sources/flutter_vlc_player_16kb/**/*.swift'

  s.dependency       'Flutter'
  s.platform         = :ios, '11.0'
  # VLCKit 4 is a unified pod for all Apple platforms.
  s.dependency       'MobileVLCKit', '3.7.3'
  s.static_framework = false
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
