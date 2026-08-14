#!/usr/bin/env ruby
# Verify assets/voicevox holds a usable offline VOICEVOX synthesis stack.
#
# The four pieces (CORE C API, its ONNX Runtime, the Open JTalk dictionary and
# Zundamon's voice model) are downloaded by scripts/download-voicevox-
# zundamon.bash rather than committed, so a missing directory is a normal
# state for a fresh checkout -- src/voicevox_tts.cxx degrades to
# RGSS::Tts.available? == false and logs why, the same way a missing TiMidity
# patch set only silences MIDI rather than crashing. This script checks that
# what *is* there is not a truncated or mismatched download, which would
# otherwise surface as a confusing dlopen/onnxruntime failure at play time
# instead of a clear error here.
#
# Usage: ruby scripts/check_voicevox_assets.rb [assets/voicevox]

dir = ARGV[0] || File.expand_path('../assets/voicevox', __dir__)

unless Dir.exist?(dir)
  puts "voicevox: none in #{dir} -- skipping " \
       '(run scripts/download-voicevox-zundamon.bash to install it, or pass ' \
       '--zundamon_tts to a build without it and RGSS::Tts.available? just ' \
       'reports false)'
  exit 0
end

errors = []

def check_elf(errors, path)
  unless File.exist?(path)
    errors << "missing #{path}"
    return
  end
  magic = File.binread(path, 4)
  errors << "#{path}: not an ELF shared library (magic #{magic.unpack1('H*')})" unless magic == "\x7fELF".b
end

check_elf(errors, File.join(dir, 'core/lib/libvoicevox_core.so'))
errors << "missing #{dir}/core/include/voicevox_core.h" unless File.exist?(File.join(dir, 'core/include/voicevox_core.h'))
check_elf(errors, File.join(dir, 'onnxruntime/lib/libvoicevox_onnxruntime.so'))

dict_dir = File.join(dir, 'dict/open_jtalk_dic_utf_8-1.11')
%w[sys.dic unk.dic matrix.bin char.bin].each do |f|
  errors << "missing #{dict_dir}/#{f}" unless File.exist?(File.join(dict_dir, f))
end

vvm = File.join(dir, 'models/0.vvm')
if File.exist?(vvm)
  # A VVM file is a zip archive (VOICEVOX CORE reads it as one); a truncated
  # download would not start with the zip local-file-header signature "PK".
  magic = File.binread(vvm, 2)
  errors << "#{vvm}: not a zip/vvm archive (magic #{magic.unpack1('H*')})" unless magic == 'PK'
else
  errors << "missing #{vvm}"
end
errors << "missing #{dir}/models/TERMS.txt (Zundamon's usage terms must travel with the model)" unless File.exist?(File.join(dir, 'models/TERMS.txt'))

if errors.empty?
  puts "voicevox: #{dir} OK"
  exit 0
end

errors.each { |e| warn "voicevox: #{e}" }
warn 'voicevox: re-run scripts/download-voicevox-zundamon.bash --force to reinstall'
exit 1
