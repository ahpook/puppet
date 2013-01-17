#
# Motivation: DMG files provide a true HFS file system
# and are easier to manage and .pkg bundles.
#
# Note: the 'apple' Provider checks for the package name
# in /L/Receipts.  Since we install multiple pkg's from a single
# source, we treat the source .pkg.dmg file as the package name.
# As a result, we store installed .pkg.dmg file names
# in /var/db/.puppet_pkgdmg_installed_<name>

require 'puppet/provider/package'
require 'facter/util/plist'

Puppet::Type.type(:package).provide :pkgdmg, :parent => Puppet::Provider::Package do
  desc "Package management based on Apple's Installer.app and
    DiskUtility.app.  This package works by checking the contents of a
    DMG image for Apple pkg or mpkg files. Any number of pkg or mpkg
    files may exist in the root directory of the DMG file system.
    Subdirectories are not checked for packages.  See
    [the wiki docs on this provider](http://projects.puppetlabs.com/projects/puppet/wiki/Package_Management_With_Dmg_Patterns)
    for more detail."

  confine :operatingsystem => :darwin
  defaultfor :operatingsystem => :darwin
  commands :installer => "/usr/sbin/installer"
  commands :hdiutil => "/usr/bin/hdiutil"
  commands :curl => "/usr/bin/curl"

  # Read HTTP proxy configurationm from Puppet's config file, or the
  # http_proxy environment variable - non-DRY dup of puppet/forge/repository.rb
  def self.http_proxy_env
    proxy_env = ENV["http_proxy"] || ENV["HTTP_PROXY"] || nil
    begin
      return URI.parse(proxy_env) if proxy_env
    rescue URI::InvalidURIError
      return nil
    end
    return nil
  end

  def self.http_proxy_host
    env = http_proxy_env

    if env and env.host then
      return env.host
    end

    if Puppet.settings[:http_proxy_host] == 'none'
      return nil
    end

    return Puppet.settings[:http_proxy_host]
  end

  def self.http_proxy_port
    env = http_proxy_env

    if env and env.port then
      return env.port
    end

    return Puppet.settings[:http_proxy_port]
  end

  # JJM We store a cookie for each installed .pkg.dmg in /var/db
  def self.instance_by_name
    Dir.entries("/var/db").find_all { |f|
      f =~ /^\.puppet_pkgdmg_installed_/
    }.collect do |f|
      name = f.sub(/^\.puppet_pkgdmg_installed_/, '')
      yield name if block_given?
      name
    end
  end

  def self.instances
    instance_by_name.collect do |name|
      new(:name => name, :provider => :pkgdmg, :ensure => :installed)
    end
  end

  def self.installpkg(source, name, orig_source)
    installer "-pkg", source, "-target", "/"
    # Non-zero exit status will throw an exception.
    File.open("/var/db/.puppet_pkgdmg_installed_#{name}", "w") do |t|
      t.print "name: '#{name}'\n"
      t.print "source: '#{orig_source}'\n"
    end
  end

  def self.installpkgdmg(source, name)
    unless source =~ /\.dmg$/i || source =~ /\.pkg$/i
      raise Puppet::Error.new("Mac OS X PKG DMG's must specify a source string ending in .dmg or flat .pkg file")
    end
    require 'open-uri'
    cached_source = source
    tmpdir = Dir.mktmpdir
    begin
      if %r{\A[A-Za-z][A-Za-z0-9+\-\.]*://} =~ cached_source
        cached_source = File.join(tmpdir, name)
        args = [ "-o", cached_source, "-C", "-", "-k", "-L", "-s", "--url", source ]

        if http_proxy_host and http_proxy_port
          args << "--proxy" << "#{http_proxy_host}:#{http_proxy_port}"
        elsif http_proxy_host and not http_proxy_port
          args << "--proxy" << http_proxy_host
        end

        begin
          curl *args
          Puppet.debug "Success: curl transfered [#{name}] (via: curl #{args.join(" ")})"
        rescue Puppet::ExecutionFailure
          Puppet.debug "curl #{args.join(" ")} did not transfer [#{name}].  Falling back to slower open-uri transfer methods."
          cached_source = source
        end
      end

      if source =~ /\.dmg$/i
        File.open(cached_source) do |dmg|
          xml_str = hdiutil "mount", "-plist", "-nobrowse", "-readonly", "-noidme", "-mountrandom", "/tmp", dmg.path
          hdiutil_info = Plist::parse_xml(xml_str)
          raise Puppet::Error.new("No disk entities returned by mount at #{dmg.path}") unless hdiutil_info.has_key?("system-entities")
          mounts = hdiutil_info["system-entities"].collect { |entity|
            entity["mount-point"]
          }.compact
          begin
            mounts.each do |mountpoint|
              Dir.entries(mountpoint).select { |f|
                f =~ /\.m{0,1}pkg$/i
              }.each do |pkg|
                installpkg("#{mountpoint}/#{pkg}", name, source)
              end
            end
          ensure
            mounts.each do |mountpoint|
              hdiutil "eject", mountpoint
            end
          end
        end
      else
        installpkg(cached_source, name, source)
      end
    ensure
      FileUtils.remove_entry_secure(tmpdir, force=true)
    end
  end

  def query
    if FileTest.exists?("/var/db/.puppet_pkgdmg_installed_#{@resource[:name]}")
      Puppet.debug "/var/db/.puppet_pkgdmg_installed_#{@resource[:name]} found"
      return {:name => @resource[:name], :ensure => :present}
    else
      return nil
    end
  end

  def install
    source = nil
    unless source = @resource[:source]
      raise Puppet::Error.new("Mac OS X PKG DMG's must specify a package source.")
    end
    unless name = @resource[:name]
      raise Puppet::Error.new("Mac OS X PKG DMG's must specify a package name.")
    end
    self.class.installpkgdmg(source,name)
  end
end
