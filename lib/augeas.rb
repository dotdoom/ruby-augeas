##
#  augeas.rb: Ruby wrapper for augeas
#
#  Copyright (C) 2008 Red Hat Inc.
#  Copyright (C) 2011 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public
#  License along with this library; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA
#
# Authors: Ionuț Arțăriși <iartarisi@suse.cz>
#          Bryan Kearney <bkearney@redhat.com>
##

require "_augeas"
require "augeas_old"


# Wrapper class for the augeas[http://augeas.net] library.
class Augeas
  private_class_method :new

  class Error                   < RuntimeError; end
  class NoMemoryError           < Error; end
  class InternalError           < Error; end
  class InvalidPathError        < Error; end
  class NoMatchError            < Error; end
  class MultipleMatchesError    < Error; end
  class LensSyntaxError         < Error; end
  class LensNotFoundError       < Error; end
  class MultipleTransformsError < Error; end
  class NoSpanInfoError         < Error; end
  class DescendantError         < Error; end
  class CommandExecutionError   < Error; end
  @@error_hash = {
    # the cryptic error names come from the C library, we just make
    # them more ruby and more human
    ENOMEM    => NoMemoryError,
    EINTERNAL => InternalError,
    EPATHX    => InvalidPathError,
    ENOMATCH  => NoMatchError,
    EMMATCH   => MultipleMatchesError,
    ESYNTAX   => LensSyntaxError,
    ENOLENS   => LensNotFoundError,
    EMXFM     => MultipleTransformsError,
    ENOSPAN   => NoSpanInfoError,
    EMVDESC   => DescendantError,
    ECMDRUN   => CommandExecutionError}


  # DEPRECATED. Create a new Augeas instance and return it.
  #
  # Use +root+ as the filesystem root. If +root+ is +nil+, use the value
  # of the environment variable +AUGEAS_ROOT+. If that doesn't exist
  # either, use "/".
  #
  # +loadpath+ is a colon-spearated list of directories that modules
  # should be searched in. This is in addition to the standard load path
  # and the directories in +AUGEAS_LENS_LIB+
  #
  # +flags+ is a bitmask (see <tt>enum aug_flags</tt>)
  #
  # When a block is given, the Augeas instance is passed as the only
  # argument into the block and closed when the block exits. In that
  # case, the return value of the block is the return value of
  # +open+. With no block, the Augeas instance is returned.
  def self.open(root=nil, loadpath=nil, flags=Augeas::NONE, &block)
    return AugeasOld::open(root, loadpath, flags, &block)
  end

  def self.create(root=nil, loadpath=nil, flags=Augeas::NONE, &block)
    aug = Augeas.open3(root, loadpath, flags)
    if block_given?
      begin
        yield aug
      ensure
        aug.close
      end
    else
      return aug
    end
  end

  # Get the value associated with +path+.
  def get(path)
    run_command :augeas_get, path
  end

  # Set one or multiple elements to path.
  # Multiple elements are mainly sensible with a path like
  # .../array[last()+1], since this will append all elements.
  def set(path, *values)
    values.flatten.each { |v| run_command :augeas_set, path, v }
  end

  # Remove all nodes matching path expression +path+ and all their
  # children.
  # Raises an <tt>Augeas::InvalidPathError</tt> when the +path+ is invalid.
  def rm(path)
    run_command :augeas_rm, path
  end

  # Return an Array of all the paths that match the path expression +path+
  #
  # Returns an empty Array if no paths were found.
  # Raises an <tt>Augeas::InvalidPathError</tt> when the +path+ is invalid.
  def match(path)
    run_command :augeas_match, path
  end

  # Add a transform under <tt>/augeas/load</tt>
  #
  # The HASH can contain the following entries
  # * <tt>:lens</tt> - the name of the lens to use
  # * <tt>:name</tt> - a unique name; use the module name of the LENS
  # when omitted
  # * <tt>:incl</tt> - a list of glob patterns for the files to transform
  # * <tt>:excl</tt> - a list of the glob patterns to remove from the
  # list that matches <tt>:incl</tt>
  def transform(hash)
    lens = hash[:lens]
    name = hash[:name]
    incl = hash[:incl]
    excl = hash[:excl]
    raise ArgumentError, "No lens specified" unless lens
    raise ArgumentError, "No files to include" unless incl
    name = lens.split(".")[0].sub("@", "") unless name

    xfm = "/augeas/load/#{name}/"
    set(xfm + "lens", lens)
    set(xfm + "incl[last()+1]", incl)
    set(xfm + "excl[last()+1]", excl) if excl
  end

  # Clear all transforms under <tt>/augeas/load</tt>. If +load+
  # is called right after this, there will be no files
  # under +/files+
  def clear_transforms
    rm("/augeas/load/*")
  end
  
  # Write all pending changes to disk.
  # Raises <tt>Augeas::CommandExecutionError</tt> if saving fails.
  def save
    begin
      run_command :augeas_save
    rescue Augeas::CommandExecutionError => e
      raise e, "Saving failed. Search the augeas tree in /augeas//error"+
        "for the actual errors."
    end

    nil
  end
  
  # Load files according to the transforms in /augeas/load or those
  # defined via <tt>transform</tt>.  A transform Foo is represented
  # with a subtree /augeas/load/Foo.  Underneath /augeas/load/Foo, one
  # node labeled 'lens' must exist, whose value is the fully
  # qualified name of a lens, for example 'Foo.lns', and multiple
  # nodes 'incl' and 'excl' whose values are globs that determine
  # which files are transformed by that lens. It is an error if one
  # file can be processed by multiple transforms.
  def load
    begin
      run_command :augeas_load
    rescue Augeas::CommandExecutionError => e
      raise e, "Loading failed. Search the augeas tree in /augeas//error"+
        "for the actual errors."
    end

    nil
  end

  private

  # Run a command and raise any errors that happen due to execution.
  #
  # +cmd+ name of the Augeas command to run
  # +params+ parameters with which +cmd+ will be called
  #
  # Returns whatever the original +cmd+ returns
  def run_command(cmd, *params)
    result = self.send cmd, *params

    errcode = error[:code]
    unless errcode.zero?
      raise @@error_hash[errcode],
      "#{error[:message]} #{error[:details]}"
    end

    if result.kind_of? Fixnum and result < 0
      # we raise CommandExecutionError here, because this is the error that
      # augtool raises in this case as well
      raise CommandExecutionError, "Command failed. Return code was #{result}."
    end

    return result
  end
  
end
