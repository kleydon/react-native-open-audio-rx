require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-open-audio-rx"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.description  = package['description']
  s.license      = package['license']
  s.authors      = package['author']            
  s.homepage     = "https://github.com/kleydon/react-native-open-audio-rx"
  s.source       = { :git => "https://github.com/kleydon/react-native-open-audio-rx.git", 
                     :tag => "#{s.version}" }

  s.requires_arc = true
  s.platforms    = { :ios => "9.0" }
  s.preserve_paths  = 'README.md', 'package.json', 'index.js', 'LICENSE'
  s.source_files    = 'ios/**/*.{h,m,mm,hpp,cpp,c,swift}'

  s.dependency "React"
  # ...

end

