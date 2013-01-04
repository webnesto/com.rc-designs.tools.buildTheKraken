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
use Getopt::Long;
use IO::File;
use List::Util qw( first );
use Utils qw( printLog extend extendNew from_json_file from_json_string emptyDirOfType replaceVariables );

use constant TRUE  => 1;
use constant FALSE => '';

#Variables

my $DEFAULT_CONFIG_FILE  = 'kraken.json';
my $BUILD_ENV_DEV       = 'dev';
my $BUILD_ENV_PROD      = 'prod';
my $BUILD_ENV_BOTH      = 'both';
my $WARNING_MESSAGE      = 'GENERATED FILE - DO NOT EDIT';
my $MIN_DIR              = 'min';
my $SCRATCH_DIR          = "tmp";
my @DIRECTORY_VALUE_KEYS = ( 'outputDir', 'sourceDir' );  # Their values will get turned into absolute paths.

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

sub getDefinedArgConfig {
  my ( $key, $value ) = @_;

  printLog( "Key-value config passed on command line: '$key' = '$value'" );

  my $config = {};

  if( $key =~ /^[^.].*\..*[^.]$/ ) {
    # Dotted notation

    my @keyParts = split /\./, $key;
        
    # Check that no key parts are empty.
    if( grep { $_ eq '' } @keyParts ) {
      printLog( "CLI config arg has invalid key: '$key'. Skipping." );
    }
        
    # The first part of the key must always be interpreted as a hash key, even if it is a number.
    my $evalConfig = '$config->{' . ( shift @keyParts ) . '}';
    for my $part ( @keyParts ) {
      # Is the part a non-negative integer?
      if( $part =~ /^\d+$/ ) {
        # Consider it an array index.
        $evalConfig .= "[$part]";
      }
      else {
        # We've got a hash key.
        $evalConfig .= "{$part}";
      }
    }
    $evalConfig .= " = '$value';";

    printLog( "Eval config: [$evalConfig]" );

    eval $evalConfig;

  }
  else {
    # Top-level key
    $config->{$key} = $value;
  }

  return $config;
}

sub getFileConfig {
  my $filepath = shift;

  printLog( "Config file passed on command-line: $filepath" );

  if( -e $filepath ) {
    if( -r $filepath ) {
      return from_json_file( $filepath );
    }
    else {
      carp "Unable to read config file '$filepath'. Skipping.";
      return {};
    }
  }
  else {
    carp "Config file '$filepath' does not exist. Skipping.";
    return {};
  }
}

sub getJsonStringConfig {
  my $jsonString = shift;

  printLog( "JSON config passed on command line: $jsonString" );

  return from_json_string( $jsonString );
}

sub getDefaultConfigs {
  return
    from_json_file( File::Spec->catfile( $Bin, $DEFAULT_CONFIG_FILE ) )
  , from_json_file( File::Spec->catfile( Cwd::getcwd(), $DEFAULT_CONFIG_FILE ) );
}

sub getSourceFiles {
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
    my $typeProps = $config->{ typeProps }{ $type };
    my $ext = $typeProps->{ extension } or croak "No extension for filetype: $type";
    my @ignores = ( @{ $config->{ ignores } }, @{ $typeProps->{ ignores } } );

    $filesForSourceCommands->{ $type } = [];

    printLog( "Getting $type source files." );
    defined $filesByTypeAndDir->{ $type } or $filesByTypeAndDir->{ $type } = {};

    # If $typeProps->{folder} is defined, look in that subdirectory of the $config->{workDir}.
    # Otherwise, look in the $config>{workDir}.
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
        unless( defined $filesByTypeAndDir->{ $type }{ $dir } ) {
          $filesByTypeAndDir->{ $type }{ $dir } = ();
        }

        find(
          sub {
            my $absFile = $File::Find::name;
            if ( $absFile =~ /\.($ext)$/) {
              push( @{ $filesByTypeAndDir->{ $type }{ $dir } }, $absFile );
              my $relFile = File::Spec->abs2rel( $absFile, $targetedSrcDir );
              push( @{ $filesForSourceCommands->{ $type } }, $relFile );
              printLog( "\t\t$_" );
            }
          }
        ,   File::Spec->catdir( $targetedSrcDir, $dir )
        );

        if( ! defined $filesByTypeAndDir->{ $type }{ $dir } ) {
          # Remove keys for extension-directory combinations with no files.
          delete $filesByTypeAndDir->{ $type }{ $dir };
        } else {
          my $numFiles = scalar @{ $filesByTypeAndDir->{ $type }{ $dir } };
          my $plural = ( $numFiles == 1 ) ? '' : 's';
          printLog( "\t\t$numFiles file$plural total" );
        }

      }
      else {
        printLog( "\t- ignore: $dir");
      }
    }
  }

  chdir $config->{workDir}; # Return from whence we came.

  return $filesByTypeAndDir, $filesForSourceCommands;
}

sub parseSourceFile {
}

sub parseProdContent {
  my ( $file, $type, $config )  = @_;

  my @definedArgs = @{ $config->{ env }{ $config->{ buildEnv } }{ definedArgs } || [] };

  my $outputDir = $config->{ sourceDir };

  my $content = '';

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
        if( ! defined Utils::indexOf( $1, @definedArgs ) ) {
          $ignoreInput = TRUE;
          $ifdefCount++;
        }

        next;
      }

      if( /$IMPORT_PATTERN/ ) {
        my $importPath = File::Spec->catfile( $outputDir, $1 );
        printLog( "\tPROD - Found import in '$file': '$importPath'" );
        my $importedContent .= parseProdContent( $importPath, $type, $config );

        printLog( '=' x 32, $importedContent, '=' x 32 );

        $content .= $importedContent;
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
  my ( $file, $type, $config ) = @_;

  my $typeProps = $config->{ typeProps }{ $type };

  my $buildEnv = $config->{ buildEnv };
  my $prependToPath = $config->{ env }{ $buildEnv }{ prependToPath };

  my $content = '';

  if( -e $file ) {
    my $fh = new IO::File( $file, 'r' );
    unless( defined $fh ) {
      croak "Could not open \"$file\" for reading: $!";
    }

    while( <$fh> ) {
      if( /$IMPORT_PATTERN/ ) {
        my $relImportPath = $1;

        my $absImportPath = File::Spec->catfile( $config->{ sourceDir }, $relImportPath );

        printLog( "\tdev - parsing file: $absImportPath" );

        my $importedContent .= parseDevContent( $absImportPath, $type, $config );
        
        printLog( '=' x 32, $importedContent, '=' x 32 );

        $content .= $importedContent;
        
        my $importString = $typeProps->{ env }{ $buildEnv }{ importString };
        if( defined $importString ) {
          $relImportPath = replaceExtension( $relImportPath, $typeProps->{ env }{ $buildEnv }{ extension_out } );

          if( defined $prependToPath ) {
            $relImportPath = File::Spec->catfile( $prependToPath, $relImportPath );
          }

          $importString =~ s/$REPLACE_PATTERN/$relImportPath/;

          printLog( "\tdev - writing importString: $importString" );
          
          $content .= $importString . $/;
        }
      }
    }

    undef $fh;
  }

  return $content;
}

sub replaceExtension {
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

  my $buildEnv = $config->{ buildEnv };

  for my $type ( keys %{$filesByTypeAndDir} ) {
    printLog( "Making $type files." );

    my $typeProps = $config->{ typeProps }{ $type };
    my $ext = $typeProps->{ extension };
    my $ext_out = $typeProps->{ extension_out };
    my $ext_build = ( $typeProps->{ build } ) ? $typeProps->{ build } : $ext;
    my $extension_out_for_env = $typeProps->{ env }{ $buildEnv }{ extension_out };
    
    my $blockComment = $typeProps->{ block_comment };
    $blockComment =~ s/$REPLACE_PATTERN/$WARNING_MESSAGE/;
    
    my $outputPath = File::Spec->catdir( $config->{ outputDir }, $ext_build, $config->{ folders }{ build } );

    # Nomenclature note: Each directory in the source-tree becomes a file in the output-tree.
    # So we are iterating over keys which are directory names, and are used to determine the
    # output file name.
    for my $dir ( keys %{ $filesByTypeAndDir->{ $type } } ){
      my $file = File::Spec->catfile( $config->{ folders }{ scratch }, "$dir.$ext_out" );

      printLog( "\tCreating new file '$file' from contents of directory '$dir'." );

      my $fh = new IO::File $file, 'w';
      unless( defined $fh ) {
        croak "Could not open file \"$file\": $!";
      }

      $fh->print( $blockComment .  $/ );
      $fh->print( $typeProps->{ prepend } );

      my $buildSorter = getBuildSorter( $typeProps->{ firsts }, $typeProps->{ lasts } );

      my @sortedSourceFiles = sort $buildSorter @{ $filesByTypeAndDir->{ $type }{ $dir } };
      
      for my $fromFile ( @sortedSourceFiles ){
        $fromFile = Cwd::realpath( $fromFile );

        printLog( "\t$buildEnv - parsing top-level file: $fromFile" );
        my $tmpFile = undef;
        if ( $buildEnv eq $BUILD_ENV_PROD ) {
          $tmpFile = parseProdContent( $fromFile, $type, $config );
        }
        elsif ( $buildEnv eq $BUILD_ENV_DEV ) {
          $tmpFile = parseDevContent( $fromFile, $type, $config );
        }


        if( $tmpFile ) {
          printLog( '=' x 32, $tmpFile, '=' x 32 );
          printLog( "\tGot content from parse method. Storing in '$file'." );
          $fh->print( $tmpFile );
        }

        my $importString = $typeProps->{ env }{ $buildEnv }{ importString };
        if( defined $importString ) {

          # Get the path to the source file, relative to the configured "outputDir" directory.
          my $relPath = File::Spec->abs2rel( $fromFile, $config->{ outputDir } );
          $relPath = replaceExtension( $relPath, $extension_out_for_env ); # If $extension_out_for_env is undefined, does nothing.
          
          # Prepend something to the path, if configured.
          my $prependToPath = $config->{ env }{ $buildEnv }{ prependToPath };
          if( defined $prependToPath ) {
            $relPath = File::Spec->catfile( $prependToPath, $relPath );
          }

          # Set the relative path in the include string.
          $importString =~ s/$REPLACE_PATTERN/$relPath/;

          printLog( "\tdev - writing top-level importString: $importString" );

          $fh->print( $importString . $/ );
        }
      }
      
      $fh->print( $typeProps->{ postpend } );

      undef $fh; # Auto-closes the filehandle.
    }

  }
}

sub moveToTarget {
  my ( $config, $filesByTypeAndDir ) = @_;
  my $bin = $config->{ folders }{ build };
  my $buildEnv = $config->{ buildEnv };
  my $doDeletes = $config->{ doDeletes };

  for my $type ( keys %{ $filesByTypeAndDir } ) {
    printLog( "Moving $type files." );
    my $typeProps = $config->{ typeProps }{ $type };
    my $ext = $typeProps->{ extension };
    my $ext_out = $typeProps->{ extension_out };
    my $buildFolder = $typeProps->{ build };

    my $perFileCommandsArrayRef = $typeProps->{ env }{ $buildEnv }{ commands }{ perFile };
    my @perFileCommands = @{ $perFileCommandsArrayRef || [] };

    # If $buildFolder is blank...
    if( ! defined $buildFolder || $buildFolder eq '' ) {
      # ...then use the default.
      $buildFolder = File::Spec->catdir( $typeProps->{ extension }, $config->{ folders }{ build } );
    }

    # Prepend the outputDir to make an absolute path.
    $buildFolder = File::Spec->catdir( $config->{ outputDir }, $buildFolder );

    # make_path ensures all the necessary parent directories are created.
    -e $buildFolder or File::Path::make_path( $buildFolder ) or croak "Cannot make buildFolder \"$buildFolder\": $!";

    if( $doDeletes ){
      printLog( "\temptying $buildFolder of .$ext_out files" );
      emptyDirOfType( $buildFolder, $ext_out );
    }

    for my $dir ( keys %{ $filesByTypeAndDir->{ $type } } ){ #TODO: this iteration doesn't seem to be working

      my $file = File::Spec->catfile( $config->{ folders }{ scratch }, "$dir.$ext_out" );
      my $processedFile = File::Spec->catfile( $config->{folders}{minimized}, "$dir.$ext_out" );
      my $finalFile = File::Spec->catfile( $buildFolder, "$dir.$ext_out" );

      if( scalar @perFileCommands > 0 ) {
        printLog( "\t$buildEnv - Running per-file commands on file: $file" );
        for my $perFileCommand ( @perFileCommands ) {
          printLog( "\t\tPer-file command template: $perFileCommand" );
          my $replacementHashref = {
            scriptsPath => $Bin
          , infile      => $file
          , outfile     => $processedFile
          };
          $perFileCommand = replaceVariables( $perFileCommand, $replacementHashref );

          printLog( "\t\tExecuting: $perFileCommand" );
          `$perFileCommand`;
          if( $? ) {
            # The command returned with a non-zero exit status.
            printLog( "\t\tThe per-file command returned exit status '" . ($? >> 8) . "'. Not using its output." );
            next;
          }

          # Copy so that the next iteration will start with the output of this iteration.
          printLog( "Copying '$processedFile' over '$file'" );
          copy( $processedFile, $file );
          # Delete the processed file so the next iteration's command does not complain it already exists.
          unlink( $processedFile );
        }
      }
      else {
        printLog( "\t\tNone found." );
      }

      unless( copy( $file, $finalFile ) ) {
        printLog( "Could not copy $file, to $finalFile: $!" );
        next;
      }

      printLog("\tcreated $finalFile" );
    }
  }
}

sub runPostProcessCommands {
  my ( $config, $filesForSourceCommands ) = @_;
  my $buildEnv = $config->{ buildEnv };

  for my $type ( keys %{ $filesForSourceCommands } ) {
    printLog( "Running post-process commands for $type." );
    my $typeProps = $config->{ typeProps }{ $type };
    my $filelist = join( ' ', @{ $filesForSourceCommands->{ $type } } );
    my @postProcessCommands = @{ $typeProps->{ env }{ $buildEnv }{ commands }{ postProcess } || [] };

    if( scalar @postProcessCommands > 0 ) {
      for my $command ( @postProcessCommands ){
        my $replacementHashref = {
          scriptsPath => $Bin
        , files       => $filelist
        , outputDir   => $config->{ outputDir }
        };
        $command = replaceVariables( $command, $replacementHashref );

        printLog( "\ttrying: $command" );
        `$command`;
      }
    }
    else {
      printLog( "\tNone found." );
    }
  }
}

sub normalizeConfigurationValues {
# Also validates.
#
# Expects:
#   $config: The configuration hash reference.
#   $workDir: The current working directory.

  printLog( 'Validating and normalizing the build configuration.' );

    my $config = shift;
    $config->{ workDir } = Cwd::getcwd();

    # Check the validity of the build enviroment setting.  It must be one of the keys
    # of the "env" hash at the top level of the config tree.  In the default configuration
    # file, the values are "prod" and "dev".
    my @validEnvironments = keys %{ $config->{ env } };
    my $buildEnv = $config->{ buildEnv };
    unless( grep { /$buildEnv/ } @validEnvironments ) {
      croak "Build environment value '$buildEnv' not found in environment list: '" . join( "', '", @validEnvironments ) . "'";
    }

    # Check that there is a set of type properties for each enumerated type.
    my @badTypes = ();
    for( @{$config->{types}} ) {
      if( ( ! defined $config->{typeProps}{$_} )
          ||
          ( ref( $config->{typeProps}{$_} ) ne 'HASH' )
        ) {
        push @badTypes, $_;
      }
    }
    if( scalar @badTypes > 0 ) {
      croak 'No properties configured for types: ' . join( ', ', @badTypes );
    }

    # Now check that the type properties hashref contains a valid 'extension' key.
    for( @{$config->{types}} ) {
      my $typeProps = $config->{typeProps}{$_};
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

    # Check that if we are not flattening imports, we have an import string for each type.
    if( ! $config->{ env }{ $buildEnv }{ flattenImports } ) {
      for( @{$config->{types}} ) {
        my $typeProps = $config->{typeProps}{$_};
        unless( defined $typeProps->{ env }{ $buildEnv }{ importString } ) {
          push @badTypes, $_;
        }
      }
      if( scalar @badTypes > 0 ) {
        croak "Configuration for environment '$buildEnv' specifies NOT flattening imports, "
          . 'but there is no importString defined for these types: ' . join( ', ', @badTypes );
      }
    }


  if( File::Spec->file_name_is_absolute( $config->{ sourceDir } ) ) {
    croak "Configuration value 'sourceDir' is an absolute path ('$config->{ sourceDir }'), but it should be relative to the path in the configuration value 'outputDir' ('$config->{ outputDir }').";
  }

    # Canonicalize paths.
    for my $dirValueKey ( @DIRECTORY_VALUE_KEYS ) {
        unless( File::Spec->file_name_is_absolute( $config->{$dirValueKey} ) ) {
            $config->{$dirValueKey} = File::Spec->catdir( $config->{workDir}, $config->{$dirValueKey} )
        }
    }

    # Ensure we have a valid scratch directory setting.
    # This should be a path relative to the "workDir" directory for the run.  Default: 'tmp'
    defined $config->{ folders }{ scratch } or $config->{ folders }{ scratch } = $SCRATCH_DIR;

    # Now make the scratch path absolute by prepending the absolute working directory path..
    $config->{ folders }{ scratch } = File::Spec->catdir( $config->{ workDir }, $config->{ folders }{ scratch } );

    # And define a minimized-resources directory path.
    $config->{ folders }{ minimized } = File::Spec->catdir( $config->{ folders }{ scratch }, $MIN_DIR );

    # Iterate over the available environments.
    for my $envKey ( keys %{ $config->{env} } ) {
      my $envConfig = $config->{ env }{ $envKey } || {};
      # Trim the prependToPath value.
      if( defined $envConfig->{ prependToPath } ) {
        $envConfig->{ prependToPath } =~ s,$TRIMMABLE_WHITESPACE,,g;
        if( $envConfig->{ prependToPath } eq '' ) {
          delete $envConfig->{ prependToPath };
        }
      }
    }

  printLog( "\tConfiguration is valid and has been normalized." );

  return $config;
}

sub setUpResources {
# Expects:
#   $config: The configuration hash reference.

    my $config = shift;

    # Set up the scratch directory.
    my $scratchDir = $config->{ folders }{ scratch };

    unless( -e $scratchDir ) {
        mkdir $scratchDir, 0777 or croak "Cannot create scratch directory \"$scratchDir\": $!";
    }

    -w $scratchDir or croak "The scratch directory is not writable: $scratchDir";

    # And now its child directory, for minimized resources.
    my $minDir = $config->{ folders }{ minimized };

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
        File::Path::remove_tree( $config->{ folders }{ scratch } );
    }

}

sub run {

  # A hashref to hold the config values passed by flag on the command-line.
  my @configs = getDefaultConfigs();

  my $showConfigOnly = FALSE;
  my $showFilesOnly = FALSE;

  my $optionsResult = GetOptions(
    'config-only'   => sub { $showConfigOnly = TRUE; $showFilesOnly = FALSE; }
  , 'files-only'    => sub { $showFilesOnly = TRUE; $showConfigOnly = FALSE; }
  , 'define:s%'     => sub { my ( undef, $key, $value ) = @_; push @configs, getDefinedArgConfig( $key, $value ); }
  , 'json-define:s' => sub { my ( undef, $jsonString ) = @_; push @configs, getJsonStringConfig( $jsonString ); }
  , '<>'            => sub { my $file = $_[0]; push @configs, getFileConfig( $file ); }
    );

  logStart();

  # This is a composite of all the default and CLI-specified config files
  my $config = normalizeConfigurationValues( extendNew( @configs ) );

  if( $showConfigOnly ) {
    printLog('','','','');
    print Data::Dumper->new( [$config], ['config'] )->Indent(3)->Dump();
    exit 0;
  }

  #TODO: implement subs iteration - allow arguments for subs - default "current" directory.

  my ( $filesByTypeAndDir, $filesForSourceCommands ) = getSourceFiles( $config );

  if( $showFilesOnly ) {
    print Data::Dumper->new( [$filesByTypeAndDir, $filesForSourceCommands], ['filesByTypeAndDir', 'filesForSourceCommands'] )->Indent(3)->Dump();
    exit 0;
  }

  # After this point, there may be changes to content on disk.

  setUpResources( $config );

  makeFiles( $config, $filesByTypeAndDir );

  moveToTarget( $config, $filesByTypeAndDir );

  cleanUpResources( $config );

  runPostProcessCommands( $config, $filesForSourceCommands );

  logEnd( $config->{ buildEnv } );
}

1;
