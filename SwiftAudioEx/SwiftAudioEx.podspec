#
# Be sure to run `pod lib lint SwiftAudioEx.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'SwiftAudioEx'
  s.version          = '1.1.0'
  s.summary          = 'Easy audio streaming for iOS'
  s.description      = <<-DESC
SwiftAudioEx is an audio player written in Swift, making it simpler to work with audio playback from streams and files.
DESC

  s.homepage         = 'https://github.com/DoubleSymmetry/SwiftAudioEx'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.authors          = { 'David Chavez'     => 'david@dcvz.io',
                        'Jørgen Henrichsen' => 'jh.henrichs@gmail.com', }
  s.source           = { :git => 'https://github.com/DoubleSymmetry/SwiftAudioEx.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version = '5.5'

  # Swift sources + vendored libopus C sources.
  # In CocoaPods, the C symbols (opus_decoder_create etc.) are bridged to Swift automatically
  # via the pod's generated umbrella header — no explicit `import Copus` needed.
  s.source_files = [
    'Sources/SwiftAudioEx/**/*.swift',
    'Sources/Copus/**/*.{c,h}',
  ]

  # Public opus headers — included in the pod umbrella header, making C symbols
  # directly accessible to Swift without a separate module import.
  s.public_header_files = 'Sources/Copus/include/*.h'

  s.dependency 'SwiftProtobuf', '~> 1.27'

  s.pod_target_xcconfig = {
    # Internal header search paths required by libopus C files
    'HEADER_SEARCH_PATHS' => [
      '$(PODS_TARGET_SRCROOT)/Sources/Copus',
      '$(PODS_TARGET_SRCROOT)/Sources/Copus/celt',
      '$(PODS_TARGET_SRCROOT)/Sources/Copus/silk',
      '$(PODS_TARGET_SRCROOT)/Sources/Copus/silk/float',
    ].join(' '),
    # Build defines required by libopus
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) OPUS_BUILD VAR_ARRAYS=1 FLOATING_POINT HAVE_LRINT=1 HAVE_LRINTF=1',
  }
end
