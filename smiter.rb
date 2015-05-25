#!/usr/bin/env ruby

require 'find'
require 'net/http'
require 'uri'
require 'json'
require 'inifile'


def zfs_get(dataset, property)
  return IO.popen("/usr/sbin/zfs get -Hp -o value #{property} #{dataset}").read.chomp
end

def sum_file_sizes(files)
  return files.inject(0) { |sum, f| sum += File.size(f) }
end

def dir_used(dir)
  return sum_file_sizes Find.find(dir)
end

def xml_rip(file, key)
  open(file).read.match %r"<#{key}>(.*)<\/#{key}>"
  return $~[1]
end

def human_size(bytes)
  return "#{bytes/1000000000} GB"
end

def sb_cmd(baseurl, args)
  uri = URI.parse("#{baseurl}/?#{URI.encode_www_form(args)}")
  res = Net::HTTP.get_response(uri)
  raise "bad http response from sb" unless res.code == '200'
  
  parsed = JSON.parse(res.body)
  parsed.default_proc = proc { |hash, key| raise "no #{key}!" }
  
  raise "sb returned: #{parsed['message']}" unless parsed['result'] == 'success'
  return parsed['data']
end


SHRINKABLE_DATASET = 'tank/srv/shows'
FREE_TARGET = 200 * 1000000000
ACTUALLY_DELETE = false

sbcfg = IniFile.load('/opt/sickbeard/config.ini')['General']
sb_url = "http://#{sbcfg['web_host']}:#{sbcfg['web_port']}#{sbcfg['web_root']}/api/#{sbcfg['api_key']}"

puts "SB: #{sb_url}"

shrinkable_mount = zfs_get(SHRINKABLE_DATASET, 'mountpoint')
pool_name = SHRINKABLE_DATASET.split('/')[0]

puts "#{SHRINKABLE_DATASET} is mounted at #{shrinkable_mount}"

shrinkable_overest = zfs_get(SHRINKABLE_DATASET, 'used').to_i
shrinkable = dir_used(shrinkable_mount)
overest_margin = shrinkable_overest - shrinkable

puts "ZFS estimates its size (#{human_size(shrinkable)}) as #{human_size(shrinkable_overest)}."
puts "This overestimation (#{human_size(overest_margin)}) can be considered free space,"

free_underest = zfs_get(pool_name, 'avail').to_i
free_corr = free_underest + overest_margin

puts "giving us #{human_size(free_corr)} free instead of (ZFS) #{human_size(free_underest)}."

to_delete = FREE_TARGET - free_corr

puts "Will free up #{human_size(to_delete)} to reach #{human_size(FREE_TARGET)} target."


nfos = Dir["#{shrinkable_mount}/*/*.nfo"].reject { |nfo| nfo.end_with? '/tvshow.nfo' }
nfos_ordered = nfos.sort_by { |f| File.mtime f }

freed_so_far = 0

nfos_ordered.each do |ep_nfo|
  break if freed_so_far >= to_delete
  
  puts "[#{human_size(to_delete - freed_so_far)} to go]  #{File.mtime ep_nfo}  #{File.basename ep_nfo}"
  
  begin
    ep_files = Dir[ep_nfo.sub(/\.nfo$/, '*')]
    ep_files_nfolast = ep_files.sort_by { |f| f.end_with?('.nfo') ? 1 : 0 }
    ep_files_used = sum_file_sizes ep_files
    
    show_nfo = File.dirname(ep_nfo) + '/tvshow.nfo'
    
    episode_hash = {
      :tvdbid  => xml_rip(show_nfo, 'id').to_i,
      :season  => xml_rip(ep_nfo, 'season').to_i,
      :episode => xml_rip(ep_nfo, 'episode').to_i,
    }
    
    res = sb_cmd(sb_url, episode_hash.merge({
      :cmd => 'episode',
      :full_path => 1,
    }))
    expect_file = res['location']
    
    puts " MISSING #{expect_file}" unless ep_files.include? expect_file or expect_file == ''
    
    if ACTUALLY_DELETE then
      res = sb_cmd(sb_url, episode_hash.merge({
        :cmd => 'episode.setstatus',
        :status => 'ignored',
        :force => 1,
      }))
      
      ep_files_nfolast.each { |f| File.delete f }
    end
    
    freed_so_far += ep_files_used
    
  #rescue
  #  puts " ERROR: #{ep_nfo}"
  end
end

