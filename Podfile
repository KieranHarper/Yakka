workspace 'Yakka'
inhibit_all_warnings!
use_frameworks!


# Shared declarations

def dependency_pods
    # Fill in as needed
end

def testing_pods
    pod 'Quick'
    pod 'Nimble', :git => 'https://github.com/Quick/Nimble.git', :branch => 'master'
end


# Framework targets

target 'Yakka-iOS' do  
    platform :ios, '8.0'
    dependency_pods
end

target 'Yakka-macOS' do  
    platform :osx, '10.10'
    dependency_pods
end

target 'Yakka-tvOS' do  
    platform :tvos, '9.0'
    dependency_pods
end

target 'Yakka-watchOS' do  
    platform :watchos, '2.0'
    dependency_pods
end


# Test targets

target 'Yakka-iOS Tests' do  
    platform :ios, '10.0'
    testing_pods
end

target 'Yakka-macOS Tests' do  
    platform :osx, '10.10'
    testing_pods
end

target 'Yakka-tvOS Tests' do  
    platform :tvos, '10.0'
    testing_pods
end
