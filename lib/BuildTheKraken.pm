#!/usr/bin/perl -w

#  ***** BEGIN MIT LICENSE BLOCK *****
#
#  Copyright (c) 2011 B. Ernesto Johnson
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.
#
#  ***** END MIT LICENSE BLOCK *****

package BuildTheKraken;

#Includes
use strict;
use warnings;

use Carp;
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Find;
use File::Path;
use File::Spec;
use FindBin qw( $Bin );
use IO::File;
use List::Util qw( first );
use Utils qw( printLog extend extendNew from_json_file emptyDirOfType replaceVariables );

use constant TRUE  => 1;
use constant FALSE => '';

#Variables

my $DEFAULT_CONFIG_FILE  = 'build.json';
my $BUILD_TYPE_DEV       = 'dev';
my $BUILD_TYPE_PROD      = 'prod';
my $BUILD_TYPE_BOTH      = 'both';
my $WARNING_MESSAGE      = 'GENERATED FILE - DO NOT EDIT';
my $MIN_DIR              = 'min';
my $SCRATCH_DIR          = "tmp";
my @DIRECTORY_VALUE_KEYS = ( 'root', 'importroot' );  # Their values will get turned into absolute paths.

# Patterns

my $IFDEF_PATTERN   = qr/#ifdef\s+(\w+)/;
my $ENDIF_PATTERN   = qr/#endif/;
my $IMPORT_PATTERN  = qr/#build_import\s+([^\s]+)/;
my $REPLACE_PATTERN = qr/-CONTENT-/;
my $TRIMMABLE_WHITESPACE = qr/^\s+|\s+$/;

#Functions

sub logStart {
  printLog(
    '++++++++++++++++'
  , 'Build The Kraken!: '
  . POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime)
  . $/
  );
}

sub logEnd {
  my ( $build ) = @_;
  printLog(
    "The Kraken is Built!: "
  .  POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime)
  .  " type:$build"
  ,  "++++++++++++++++"
  );
}

sub printOrder ($) {
#  my $val = $_[0];
#  if( $val == 1 ) {
#    printLog( "B should come first\n" );
#    return;
#  }
#  if( $val == -1 ) {
#    printLog( "A should come first\n" );
#    return;
#  }
#  printLog( "Neither should come first, this is borken!\n" );
}

sub getConfigPath {
  my ( $path ) = @_;

  if( File::Spec->file_name_is_absolute( $path ) ){
    return $path;
  } else {
    return File::Spec->catfile( Cwd::getcwd(), $path );
  }
}

sub getConfigs {
# Expects a list of config file paths, either absolute or relative to the working directory.
#
# The string '-dev' may be passed as any of the arguments to add { 'buildType' => 'dev' } to the
# returned list of hash references containing configuration data.
#
# Order is important.  Values for duplicate configuration keys override earlier ones.  So the
# values for duplicate configuration keys, if any, in the working directory configuration
# override those in the script directory.  And configuration file paths at the end of the
# command-line will have precedence over earlier paths, while the entire set of passed arguments
# has precedence over the two defaults.

  my @configs = (
    from_json_file( File::Spec->catfile( $Bin, $DEFAULT_CONFIG_FILE ) )
  ,  from_json_file( File::Spec->catfile( Cwd::getcwd(), $DEFAULT_CONFIG_FILE ) )
  );


  my $argConfig = {};
  for my $arg ( @_ ){
    if( $arg eq "-dev" ){  # Arguments override any config files
      $argConfig->{ buildType } = $BUILD_TYPE_DEV;
    } else {
      printLog("config file passed as arg: $arg" );
      push( @configs, from_json_file( getConfigPath( $arg ) ) );
    }
  }

  push( @configs, $argConfig );

  return ( @configs );
}

sub getFilenamesByType {
# Expects 1 argument:
#   $config: A configuration hash reference.
#
# Returns:
#   $filesByTypeAndDir: A hashref keying the type's name to a hashref whose keys are
#                       directories relative to the $config->{workDir} and values are an array of 
#                       absolute paths to files in that directory with the type's extension.
#   $filesForSourceCommands: A hashref with file-extension keys whose values are a reference 
#                            to an array containing the paths to the same files returned in
#                            the returned data, but with the path relative to the $targetedSrcDir.

  my ( $config ) = @_;

  my $filesByTypeAndDir = {};
        my $filesForSourceCommands = {};

  for my $type ( @{ $config->{ types } } ){
    my $typeProps = $config->{ typeProps }->{ $type };
    my $ext = $typeProps->{ extension } or croak "No extension for filetype: $type";
    my @ignores = ( @{ $config->{ ignores } }, @{ $typeProps->{ ignores } } );

    $filesForSourceCommands->{ $type } = [];

    printLog( 'processing $ext' );
    defined $filesByTypeAndDir->{ $type } or $filesByTypeAndDir->{ $type } = {};

    # If $typeProps->{folder} is defined, look in that subdirectory of the $config->{workDir}.
    # Otherwise, look in the $config->{workDir}.
    my $targetedSrcDir = ( defined $typeProps->{folder} ) ?
        File::Spec->catdir( $config->{workDir}, $typeProps->{folder} ) :
        $config->{workDir};

    chdir $targetedSrcDir;

    for my $dir ( glob '*' ) {
      -d $dir or next;    # Only using folders.  Skipping files.
      if( indexOfPatternArray( $dir, \@ignores ) == -1 ) {
        # If we are not configured to ignore this directory...
        printLog( "\t+ folder: $dir" );

        # Make sure there is an array allocated for the extension and directory.
        unless( defined $filesByTypeAndDir->{ $type }->{ $dir } ) {
          $filesByTypeAndDir->{ $type }->{ $dir } = ();
        }

        find(
          sub {
            my $absFile = $File::Find::name;
            if ( $absFile =~ /\.($ext)$/) {
              push( @{ $filesByTypeAndDir->{ $type }->{ $dir } }, $absFile );
              my $relFile = File::Spec->abs2rel( $absFile, $targetedSrcDir );
              push( @{ $filesForSourceCommands->{ $type } }, $relFile );
              printLog( "\t\tfile: $_" );
            }
          }
        ,   File::Spec->catdir( $targetedSrcDir, $dir )
        );

        if( ! defined $filesByTypeAndDir->{ $type }->{ $dir } ) {
          # Remove keys for extension-directory combinations with no files.
          delete $filesByTypeAndDir->{ $type }->{ $dir };
        } else {
          my $numFiles = @{ $filesByTypeAndDir->{ $type }->{ $dir } };
          printLog( "\t\tTOTAL:$ext:$dir: $numFiles" );
        }

      } else {
        printLog( "\t- ignore: $dir");
      }
    }
  }

  chdir $config->{workDir}; # Return to whence we came.

  return $filesByTypeAndDir, $filesForSourceCommands;
}

sub parseProdContent {
  my ( $file, $includedArgsRef, $outputDir )  = @_;
  my $importPath;
  my $content;

  if( -e $file ){
    my $fh = new IO::File( $file, "r" );
    unless( defined $fh ) {
      croak "Could not open \"$file\" for reading: $!";
    }

    my $ignoreInput = FALSE;

    # This is just for the current file.
    my $ifdefCount = 0;

    while ( <$fh> ) {
      if( $ignoreInput ) {
        # We are inside an #ifdef block whose arg is NOT defined.
        # Ignore everything except the #endif.
        next unless( /$ENDIF_PATTERN/ || /$IFDEF_PATTERN/ );

      }

      if( /$ENDIF_PATTERN/ ) {
        if( $ignoreInput ) {
            $ifdefCount--;
        }
        else {
          if( $ifdefCount > 0 ) {
            carp "File \"$file\" is has too many #endif lines.";
          }
        }
        if( $ifdefCount == 0 ) {
          $ignoreInput = FALSE;
        }
        next;
      }

      if( /$IFDEF_PATTERN/ ) {
        if( $ignoreInput ) {
          # Just increment the nesting counter.
          $ifdefCount++;
          next;
        }

        # We are not already ignoring input.  Check this #ifdef.
        if( ! defined Utils::indexOf( $1, $includedArgsRef ) ) {
          $ignoreInput = TRUE;
          $ifdefCount++;
        }

        next;
      }

      if( /$IMPORT_PATTERN/ ) {
        $importPath = File::Spec->catfile( $outputDir, $1 );
        printLog( "prod - importing: $importPath", '' );
        $content .= parseProdContent( $importPath, $includedArgsRef, $outputDir );
        next;
      }
      
      # This is just a regular, not a directive, line.
      $content .= $_;

    }
    undef $fh;

    if( $ifdefCount > 0 ) {
      my $lines = ( $ifdefCount > 1 ) ? 'lines' : 'line';
      carp "File \"$file\" is missing $ifdefCount closing #endif $lines.";
    }
  }
  else {
    croak "Expected file does not exist for parsing: $file";
  }
  return $content;
}

sub parseDevContent {
  my ( $file, $typeProps, $config ) = @_;

  my $content = '';

  if( -e $file ) {
    my $fh = new IO::File( $file, 'r' );
    unless( defined $fh ) {
      croak "Could not open \"$file\" for reading: $!";
    }

    while( <$fh> ) {
      if( /$IMPORT_PATTERN/ ) {
        my $relImportPath = $1;

        if( defined $config->{ dev }->{ url } ) {
          $relImportPath = File::Spec->catfile( $config->{ dev }->{ url }, $relImportPath );
        }
        $relImportPath = replaceExtension( $relImportPath, $typeProps->{ extension_out_dev } );

        my $absImportPath = File::Spec->catfile( $config->{ importroot }, $relImportPath );

        my $includeString = $typeProps->{ dev_include };
        $includeString =~ s/$REPLACE_PATTERN/$relImportPath/;

        printLog( "\tdev - importing: $includeString" );

        $content .= parseDevContent( $absImportPath, $typeProps, $config );
        
        $content .= $includeString . $/;
      }
    }

    undef $fh;
  }

  return $content;
}

sub replaceExtension{
  my ( $path, $ext ) = @_;
  if( $ext ){
    $path =~ s,[^.]+$,$ext,;
  }
  return $path;
}


sub getFolderToIndex {
  my ( $folders, $index ) = @_;
  return join( "/", @{$folders}[0..( $index + 0 )] );
}

sub indexOfPatternArray{
# Expects:
#   $target: The scalar value we are looking for.
#   $array_ref: A reference to an array in which we will search.
#
# Returns:
#   $index: The index of the item in the array matched by the $target.

  my ( $target, $array_ref ) = @_;
  my $index = first {
    if ( $array_ref->[$_] =~ /^=~/ ){
      my $re = substr $array_ref->[$_], 2;
      $target =~ $re;
    }
    elsif ( $array_ref->[$_] =~ /^!~/ ){
      my $re = substr $array_ref->[$_], 2;
      $target !~ $re;
    }
    else {
      $target eq $array_ref->[$_];
    }
  } 0 .. $#$array_ref;

  return ( defined $index ) ? $index : -1;
}

sub getBuildSorter {
  my ( $firsts, $lasts ) = @_;

  return sub {
    my $la = $a; # lc $a;
    my $lb = $b; #lc $b;

#    printLog( '', $la, $lb );

    my @firsts = @{ $firsts };
    my @lasts = @{ $lasts };

    my @aDirs = split(/\\|\//, $la );
    my @bDirs = split(/\\|\//, $lb );

    my $aFolder = join( "/", @aDirs[0..(@aDirs - 2)] );
    my $bFolder = join( "/", @bDirs[0..(@bDirs - 2)] );

#    printLog( 'a folder and b folder: ', $aFolder, $bFolder );

    my $aFirstIndex = -1;
    my $bFirstIndex = -1;
    my $aLastIndex = -1;
    my $bLastIndex = -1;

    if( scalar @firsts > 0 ) { # An array of "first" filenames/patterns has been provided... find the index of current sort files in array
      $aFirstIndex = indexOfPatternArray( $aDirs[ $#aDirs ], $firsts );
      $bFirstIndex  = indexOfPatternArray( $bDirs[ $#bDirs ], $firsts );
    }
    if( scalar @lasts > 0 ) { # An array of "last" filenames/patterns has been provided... find the index of current sort files in array
      $aLastIndex = indexOfPatternArray( $aDirs[ $#aDirs ], $lasts );
      $bLastIndex = indexOfPatternArray( $bDirs[ $#bDirs ], $lasts )
    }

    my $aIsAFirst = ( $aFirstIndex > -1 );
    my $bIsAFirst = ( $bFirstIndex > -1 );
    my $aIsALast  = ( $aLastIndex > -1 );
    my $bIsALast  = ( $bLastIndex > -1 );

    if( $aIsAFirst or $bIsAFirst ){ # If both are marked for first and are in the same directory, use the  passed array file sorting rules
      if(
        ( $aIsAFirst and $bIsAFirst )
      and
        (  $aFolder eq $bFolder )
      ) {
#        printLog( "both are marked for first and are in the same directory, use the  passed array file sorting rules." );
        printOrder( $aFirstIndex <=> $bFirstIndex );
        return $aFirstIndex <=> $bFirstIndex;
      }
      # If one has control file and a shorter path than the other, it should go first
      # If one has control file and a longer path than the other, it should go last
      if(
        $aIsAFirst
        &&(
          (
            ( @aDirs < @bDirs )
            # and bDirs up 2 aDirs folder are identical
            &&( $aFolder eq getFolderToIndex( \@bDirs, @aDirs-2 ))
          )
          ||
          ( $aFolder eq $bFolder )
        )
      ){
        printOrder( -1 );
        return -1
      }
      if(
        $bIsAFirst
        &&(
          (
            ( @bDirs < @aDirs )
            &&( $bFolder eq getFolderToIndex( \@aDirs, @bDirs-2 ))
          )
          ||
          ( $aFolder eq $bFolder )
        )
      ){
        printOrder(1);
        return 1;
      }
      #printLog( "a or b is a first, but no handling has been done: prob?\n\n." ); # This log is misleading, may happen even when there's no problem
    }

    if( $aIsALast or $bIsALast ){
      # If both are marked for first and are in the same directory, use the  passed array file sorting rules
      if(
        ( $aIsALast and $bIsALast )
      and
        (  $aFolder eq $bFolder )
      ) {
        printOrder( $aLastIndex <=> $bLastIndex );
        return $aLastIndex <=> $bLastIndex;
      }
      # If one has control file and a shorter path than the other, it should go last
      # If one has control file and a longer path than the other, it should go first
      if(
        $bIsALast
        &&(
          (
            ( @bDirs < @aDirs )
            &&( $bFolder eq getFolderToIndex( \@aDirs, @bDirs-2 ))
          )
          ||
          ( $aFolder eq $bFolder )
        )
      ) {
        printOrder( -1 );
        return -1
      }
      if(
        $aIsALast
        &&(
          (
            ( @aDirs < @bDirs )
            &&( $aFolder eq getFolderToIndex( \@bDirs, @aDirs-2 ))
          )
          ||
          ( $aFolder eq $bFolder )
        )
      ){
        printOrder( 1 );
        return 1;
      }
    }

    # else just do a normal evaluation
    my $ret = $la cmp $lb;
    printOrder( $ret );
    $la cmp $lb;
  }
}

sub makeFiles {
# Expects:
#   $config: The configuration hash reference.
#   $filesByTypeAndDir: A hashref keying the type's extension to a hashref whose keys are
#                       directories relative to the $workDir and values are an array of 
#                       absolute paths to files in that directory with the required extension.

  my ( $config, $filesByTypeAndDir ) = @_;

  my $build = $config->{ buildType };
  my $keepers = $config->{ prod }->{ keep };

  for my $type ( keys %{ $filesByTypeAndDir } ) {
    my $typeProps = $config->{ typeProps }->{ $type };
    my $ext = $typeProps->{ extension };
    my $ext_out = $typeProps->{ extension_out };
    my $ext_build = ( $typeProps->{ build } ) ? $typeProps->{ build } : $ext;
    my $extension_out_dev = $typeProps->{ extension_out_dev };
    
    my $blockComment = $typeProps->{ block_comment };
    $blockComment =~ s/$REPLACE_PATTERN/$WARNING_MESSAGE/;
    
    my $includeString = $typeProps->{dev_include};
    my $outputPath = File::Spec->catdir( $config->{root}, $ext_build, $config->{ folders }->{ build } );

    # Nomenclature note: Each directory in the source-tree becomes a file in the output-tree.
    # So we are iterating over keys which are directory names, but they are used here as the file name.
    for my $filename ( keys %{ $filesByTypeAndDir->{ $type } } ){
      my $file = File::Spec->catfile( $config->{ folders }->{ scratch }, "$filename.$ext_out" );

      printLog( "making file $file" );
      my $fh = new IO::File $file, 'w';
      unless( defined $fh ) {
        croak "Could not open file \"$file\": $!";
      }

      $fh->print( $blockComment .  $/ );
      $fh->print( $typeProps->{ prepend } );

      my $buildSort = getBuildSorter( $typeProps->{ firsts }, $typeProps->{ lasts } );

      my @fromFiles = sort $buildSort @{ $filesByTypeAndDir->{ $type }->{ $filename } };
      
      for my $fromFile ( @fromFiles ){
        $fromFile = Cwd::realpath( $fromFile );

        printLog( "\tadding $fromFile" );

        if ( $config->{ buildType } eq $BUILD_TYPE_PROD ) {
          my $tmpFile = parseProdContent( $fromFile, $keepers, $config->{ importroot } );
          $fh->print( $tmpFile ) if $tmpFile;
        }
        elsif ( $config->{ buildType } eq $BUILD_TYPE_DEV ) {
          my $tmpFile = parseDevContent( $fromFile, $typeProps, $config );
          $fh->print( $tmpFile ) if $tmpFile;

          # Get the path to the source file, relative to the configured "root" directory.
          my $relPath = File::Spec->abs2rel( $fromFile, $config->{root} );
          $relPath = replaceExtension( $relPath, $extension_out_dev ); # If $extension_out_dev is undefined, does nothing.

          if( defined $config->{dev}->{url} ) {
            $relPath = File::Spec->catfile( $config->{dev}->{url}, $relPath );
          }

          my $includeString = $typeProps->{dev_include};
          $includeString =~ s/$REPLACE_PATTERN/$relPath/;

          printLog( "\tdev - including: $includeString" );
          $fh->print( $includeString . $/ );
        }

      }
      
      $fh->print( $typeProps->{ postpend } );

      undef $fh; # Auto-closes the filehandle.
    }

  }
}

sub moveToTarget {
  my ( $config, $filesByTypeAndDir ) = @_;
  my $bin = $config->{ folders }->{ build };
  my $build = $config->{ buildType };
  my $root = $config->{ root };
  my $doDeletes = $config->{ doDeletes };

  for my $type ( keys %{ $filesByTypeAndDir } ) {
    my $typeProps = $config->{ typeProps }->{ $type };
    my $ext = $typeProps->{ extension };
    my $ext_out = $typeProps->{ extension_out };
    my $buildFolder = $typeProps->{ build };
    my @commands;
    if( $build eq $BUILD_TYPE_PROD ){
      @commands = ( $typeProps->{ production_commands } ) ? @{ $typeProps->{ production_commands } } : ();
    } else {
      @commands = ( $typeProps->{ development_commands } ) ? @{ $typeProps->{ development_commands } } : ();
    }

    # If $buildFolder is blank...
    if( ! defined $buildFolder || $buildFolder eq '' ) {
      # ...then use the default.
      $buildFolder = File::Spec->catdir( $typeProps->{ extension }, $config->{ folders }->{ build } );
    }

    # Prepend the root directory to make an absolute path.
    $buildFolder = File::Spec->catdir( $root, $buildFolder );

    # make_path ensures all the necessary parent directories are created.
    -e $buildFolder or File::Path::make_path( $buildFolder ) or croak "Cannot make buildFolder \"$buildFolder\": $!";

    if( $doDeletes ){
      printLog( "\temptying $buildFolder of .$ext_out files" );
      emptyDirOfType( $buildFolder, $ext_out );
    }

    for my $filename ( keys %{ $filesByTypeAndDir->{ $type } } ){ #TODO: this iteration doesn't seem to be working

      my $file = File::Spec->catfile( $config->{ folders }->{ scratch }, "$filename.$ext_out" );
      my $minFile = File::Spec->catfile( $config->{folders}->{minimized}, "$filename.$ext_out" );
      my $finalFile = File::Spec->catfile( $buildFolder, "$filename.$ext_out" );
      my $sourceFile = $file;

      if( $build eq $BUILD_TYPE_PROD ) {
        # This line accounts for the case where there are no production commands.
        copy( $file, $minFile ) or printLog( "Could not copy $file to $minFile: $!" );
        printLog( "running production commands on file: $file" );
        for my $command ( @commands ){
          printLog( "rawcommand: $command" );
          my $replacementHashref = {
            scriptsPath => $Bin
          , infile      => $file
          , outfile     => $minFile
          };
          $command = replaceVariables( $command, $replacementHashref );

          printLog( "prod - trying $command" );
          `$command`;
        }
        $sourceFile = $minFile;
      }
      
      printLog( "sourceFile: $sourceFile" );

      unless( copy( $sourceFile, $finalFile ) ) {
        printLog( "Could not copy $sourceFile, to $finalFile: $!" );
        next;
      }

      printLog("\tcreated $finalFile" );
    }
  }
}

sub doSourceCommands {
  printLog( "beginning source commands" );
  my ( $config, $filesForSourceCommands ) = @_;
  my $root = $config->{ root };
  my $build = $config->{ buildType };

  for my $type ( keys %{ $filesForSourceCommands } ) {
    my $typeProps = $config->{ typeProps }->{ $type };
    my $filelist = join( ' ', @{ $filesForSourceCommands->{ $type } } );
    my @source_commands = @{ $typeProps->{ source_commands } || [] };
    my $envForSourceCommands = $typeProps->{ do_source_commands } || '';

    my $doRunCommands = ( $envForSourceCommands eq $build
                          or $envForSourceCommands eq $BUILD_TYPE_BOTH );

    if( $doRunCommands ){
      for my $command ( @source_commands ){
        my $replacementHashref = {
          scriptsPath => $Bin
        , files       => $filelist
        , root        => $root
        };
        $command = replaceVariables( $command, $replacementHashref );

        printLog( "\ttrying: $command" );
        `$command`;
      }
    }
  }

  printLog( "ending source commands" );
}

sub normalizeConfigurationValues {
# Also validates.
#
# Expects:
#   $config: The configuration hash reference.
#   $workDir: The current working directory.

    my $config = shift;
    my $workDir = shift || Cwd::getcwd();
    $config->{ workDir } = Cwd::abs_path( $workDir );

    # Check that there is a set of type properties for each enumerated type.
    my @badTypes = ();
    for( @{$config->{types}} ) {
      if( ( ! defined $config->{typeProps}->{$_} )
          ||
          ( ref( $config->{typeProps}->{$_} ) ne 'HASH' )
        ) {
        push @badTypes, $_;
      }
    }
    if( scalar @badTypes > 0 ) {
      croak 'No properties configured for types: ' . join( ', ', @badTypes );
    }

    # Now check that the type properties hashref contains a valid 'extension' key.
    for( @{$config->{types}} ) {
      my $typeProps = $config->{typeProps}->{$_};
      if( ! defined $typeProps->{extension} ) {
        push @badTypes, $_;
        next;
      }
      $typeProps->{extension} =~ s,$TRIMMABLE_WHITESPACE,,g;
      
      # The 'a' flag restricts "\w" to [A-Za-z0-9_].
      if( $typeProps->{extension} !~ m,^\w+$,a ) {
        push @badTypes, $_;
        next;
      }

      # If we are here, we have a valid extension for this type.  So we can normalize
      # other type properties.
      defined $typeProps->{extension_out} or $typeProps->{extension_out} = $typeProps->{extension};

    }
    if( scalar @badTypes > 0 ) {
      croak 'Missing or invalid extensions configured for types: ' . join( ', ', @badTypes );
    }


    # The only valid values are 'prod' ($BUILD_TYPE_PROD) and 'dev' ($BUILD_TYPE_DEV).
    # If the provided value is not $BUILD_TYPE_DEV, we coerce it to $BUILD_TYPE_PROD.
    $config->{ buildType } eq $BUILD_TYPE_DEV or $config->{ buildType } = $BUILD_TYPE_PROD;

    # $config->{importroot} is relative to $config->{root}.
    # So cat them before canonicalizing it below.
    $config->{importroot} = File::Spec->catdir( $config->{root}, $config->{importroot} );

    # Canonicalize paths.
    for my $dirValueKey ( @DIRECTORY_VALUE_KEYS ) {
        unless( File::Spec->file_name_is_absolute( $config->{$dirValueKey} ) ) {
            $config->{$dirValueKey} = Cwd::abs_path( File::Spec->catdir( $config->{workDir}, $config->{$dirValueKey} ) )
        }
    }

    # Ensure we have a valid scratch directory setting.
    # This should be a path relative to the "root" directory for the run.  Default: 'tmp'
    defined $config->{ folders }->{ scratch } or $config->{ folders }->{ scratch } = $SCRATCH_DIR;

    # Now make the scratch path absolute.
    $config->{ folders }->{ scratch } = Cwd::abs_path( $config->{ folders }->{ scratch } );

    # And define a minimized-resources directory path.
    $config->{ folders }->{ minimized } = File::Spec->catdir( $config->{ folders }->{ scratch }, $MIN_DIR );


    if( defined $config->{dev}->{url} ) {
      # Trim it.
      $config->{dev}->{url} =~ s,$TRIMMABLE_WHITESPACE,,g;
      if( $config->{dev}->{url} eq '' ) {
        undef $config->{dev}->{url};
      }
    }
    

    return $config;
}

sub setUpResources {
# Expects:
#   $config: The configuration hash reference.

    my $config = shift;

    # Set up the scratch directory.
    my $scratchDir = $config->{ folders }->{ scratch };

    unless( -e $scratchDir ) {
        mkdir $scratchDir, 0777 or croak "Cannot create scratch directory \"$scratchDir\": $!";
    }

    -w $scratchDir or croak "The scratch directory is not writable: $scratchDir";

    # And now its child directory, for minimized resources.
    my $minDir = $config->{ folders }->{ minimized };

    unless( -e $minDir ) {
        mkdir $minDir, 0777 or croak "Cannot create minimized resources directory \"$minDir\": $!";
    }

    -w $minDir or croak "The minimized resources directory is not writable: $minDir";

}

sub cleanUpResources {
# Expects:
#   $config: The configuration hash reference.

    my $config = shift;

    unless( $config->{ keepScratch } ) {
        # Handles its own carping or croaking on errors.
        File::Path::remove_tree( $config->{ folders }->{ scratch } );
    }

}

sub run {

  logStart();

  # This is a composite of all the default and CLI-specified config files
  my $config = normalizeConfigurationValues( extendNew( getConfigs( @_ ) ) );

  setUpResources( $config );

  #TODO: implement subs iteration - allow arguments for subs - default "current" directory.

  my ( $filesByTypeAndDir, $filesForSourceCommands ) = getFilenamesByType( $config );

  makeFiles( $config, $filesByTypeAndDir );

  moveToTarget( $config, $filesByTypeAndDir );

  cleanUpResources( $config );

  doSourceCommands( $config, $filesForSourceCommands );

  logEnd( $config->{ buildType } );
}

1;
