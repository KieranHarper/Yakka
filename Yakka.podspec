#
# Be sure to run `pod lib lint Yakka.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'Yakka'
  s.version          = '0.2.0'
  s.summary          = 'A toolkit for coordinating the doing of stuff'

  s.description      = <<-DESC
Yakka is designed for throwaway code you just need run asynchronously in the background, as well as for creating reusable task classes that encapsulate less trivial processes
                       DESC

  s.homepage         = 'https://github.com/KieranHarper/Yakka'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Kieran Harper' => 'kieranjharper@gmail.com' }
  s.source           = { :git => 'https://github.com/KieranHarper/Yakka.git', :tag => s.version.to_s }
  s.social_media_url = 'https://twitter.com/KieranTheTwit'
  s.ios.deployment_target = '8.0'
  s.source_files = 'Yakka/Classes/**/*'
  s.frameworks = 'Foundation'
end
