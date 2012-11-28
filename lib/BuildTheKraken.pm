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
use Utils qw( printLog extend extendNew from_json_file emptyDirOfType );

#Variables

my $DEFAULT_CONFIG_FILE = "build.json";
my $REPLACE = "-CONTENT-";           # Used in replacement of dev build strings.
my $BUILD_TYPE_DEV    = 'dev';
my $BUILD_TYPE_PROD   = 'prod';
my $WARNING = 'GENERATED FILE - DO NOT EDIT';
my $MIN = "min";
my $SCRATCH_DIR = "tmp";
my @DIRECTORY_VALUE_KEYS = ( 'root', 'importroot' );

#Functions

sub logStart {
  printLog(
    "++++++++++++++++"
  ,  "Build The Kraken!: "
  .  POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime)
  .  $/
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
  foreach my $arg ( @_ ){
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
    my $typeProps = $config->{ typeProps }->{ $type } or croak "No properties for filetype: $type";
    my $ext = $typeProps->{ extension } or croak "No extension for filetype: $type";
    my @ignores = ( @{ $config->{ ignores } }, @{ $typeProps->{ ignores } } );

    $filesForSourceCommands->{ $ext } = [];

    printLog( 'processing $ext' );
    defined $filesByTypeAndDir->{ $type } or $filesByTypeAndDir->{ $type } = {};

    # If $typeProps->{folder} is defined, look in that subdirectory of the $config->{workDir}.
    # Otherwise, look in the $config->{workDir}.
    my $targetedSrcDir = ( defined $typeProps->{folder} ) ?
        File::Spec->catdir( $config->{workDir}, $typeProps->{folder} ) :
        $config->{workDir};

    chdir $targetedSrcDir;

    for my $dir ( glob "*" ) {
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
              push( @{ $filesForSourceCommands->{ $ext } }, $relFile );
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
  my ( $file, $argStates, $includedArgs, $workDir )  = @_;
  my @argStates = @{ $argStates };
  my @includedArgs = @{ $includedArgs };
  my $importPath;
  my $ret;

  if( -e $file ){
    my $fileIO = new IO::File( $file, "r" ) or die "could not open $file";
    while ( my $line = $fileIO->getline() ) {

      if ( $line =~ /\#build_import\s*([^\s]*)/ ) {
        $importPath = File::Spec->catfile( $workDir, $1 );
        printLog( "prod - importing: $importPath \n\n" );
        $ret.= parseProdContent( $importPath, \@argStates, \@includedArgs, $workDir );
      } else {

        if(
          ( $line =~ /\#endif/ )
        &&  ( scalar( @argStates ) > 1 ) #ensure that there's an argState left to shift (protects against forgotten "endifs" left in files without openers)
        ){
          shift( @argStates );
          next;
        }
        if ( $line =~ /\#ifdef\s*(\w+)/ ) {
          my $arg = $1;
          if ( defined Utils::indexOf( $arg, \@includedArgs ) && ( $argStates[0] ) ) {
            unshift( @argStates, 1 );
          } else {
            unshift( @argStates, 0 );
          }
        } #TODO: consider reversal of logic for ifndef directives.  What's their use in a JS build system?
        $ret.= $line if ( $argStates[0] );
      }

    }
    undef $fileIO;
  } else {
            croak "Expected file does not exist for parsing: $file";
  }
  return $ret;
}

sub parseDevContent {
  my ( $file, $includeString, $sourceUrl, $workDir, $extension_out_dev ) = @_;
  my $tmpStr;
  my $importPath;
  my $import;
  my $recurse;
  my $ret;

  if( -e $file ){
    my $fileIO = new IO::File( $file, "r" ) or die "could not open $file";
    while ( my $line = $fileIO->getline() ) {

      if ( $line =~ /\#build_import\s*([^\s]*)/ ) {
        $import = "$sourceUrl$1";
        $import = replaceExtension( $import, $extension_out_dev );
        $tmpStr = $includeString;
        $tmpStr =~ s/$REPLACE/$import/;
        $importPath = File::Spec->catfile( $workDir, $import );
        printLog( "\tdev - importing: $tmpStr" );
        $recurse = parseDevContent( $importPath, $includeString, $sourceUrl, $extension_out_dev );
        if( $recurse ){
          $ret.= $recurse;
        }
        $ret.= $tmpStr."\n";
      }

    }
    undef $fileIO;
  }
  return $ret;
}

sub replaceExtension{
  my ( $path, $ext ) = @_;
  if( $ext ){
    $path =~ s/(.*)\.[^\.]*$/$1.$ext/;
  }
  return $path;
}


sub getFolderToIndex {
  my ( $folders, $index ) = @_;
  my $return = join( "/", @{$folders}[0..( $index + 0 )] );
  #printLog( "getFolderToIndex:\n @{$folders} \n $index" );
  #printLog( "  return: $return \n" );
  return $return;
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

    my $aIsAFirst = ( $aFirstIndex > -1 ) ? 1 : 0;
    my $bIsAFirst = ( $bFirstIndex > -1 ) ? 1 : 0;
    my $aIsALast = ( $aLastIndex > -1 ) ? 1 : 0;
    my $bIsALast = ( $bLastIndex > -1 ) ? 1 : 0;

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

  my $scratch = $config->{ folders }->{ scratch };
  my $folders_build = $config->{ folders }->{ build };
  my $importroot = $config->{ importroot };
  my $build = $config->{ buildType };
  my $sourceUrl = $config->{ dev }->{ url };
  my $keepers = $config->{ prod }->{ keep };
  my $type;
  my $ext;
  my $ext_out;
  my $ext_build;
  my $fileName;
  my $file;
  my $fromFile;
  my $typeProps;
  my $blockComment;
  my $buildSort;
  my $includeString;
  my $extension_out_dev;
  my $tmpFile;
  my $tmpStr;
  my $relPath;
  my $outputPath;
  my @argStates;
  my @fromFiles;

#HERE

  foreach $type ( keys %{ $filesByTypeAndDir } ) {
    $typeProps = $config->{ typeProps }->{ $type };
    $ext = $typeProps->{ extension };
    $ext_out = $typeProps->{ extension_out } ? $typeProps->{ extension_out } : $ext;
    $ext_build = ( $typeProps->{ build } ) ? $typeProps->{ build } : $ext;
    $extension_out_dev = $typeProps->{ extension_out_dev };
    $blockComment = $typeProps->{ block_comment };
    $blockComment =~ s/$REPLACE/$WARNING/;
     $includeString = $typeProps->{dev_include};
    $outputPath = File::Spec->catdir( $config->{root}, $ext_build, $folders_build );

    foreach $fileName ( keys %{ $filesByTypeAndDir->{ $type } } ){
      $file = File::Spec->catfile( $scratch, "$fileName.$ext_out" );

      printLog( "making file: $file" );
      open FILE, ">$file" or die "Could not open $file\n";
      print FILE $blockComment."\n";
      print FILE $typeProps->{ prepend };

      @argStates = (1);

      $buildSort = getBuildSorter( $typeProps->{ firsts }, $typeProps->{ lasts } );

      @fromFiles = sort $buildSort @{ $filesByTypeAndDir->{ $type }->{ $fileName } };
      foreach $fromFile ( @fromFiles ){
        $fromFile = Cwd::realpath( $fromFile );
        printLog( "\tadding $fromFile" );
        if ( $build eq $BUILD_TYPE_PROD ) {
          $tmpFile = parseProdContent( $fromFile, \@argStates, $keepers, $importroot );
          print FILE $tmpFile if $tmpFile;
        } elsif ( $build eq $BUILD_TYPE_DEV ) {
          my $tmpStr;
          my $arg;
          $tmpStr = parseDevContent( $fromFile, $includeString, $sourceUrl, $importroot , $extension_out_dev );
          if( $tmpStr ){
            print FILE $tmpStr;
          }

          # generate relative path
          $relPath = File::Spec->abs2rel( $fromFile, $config->{root} ); #$fromFile; #

          $relPath = "$sourceUrl$relPath";    #remains relative as long as $sourceUrl has not been set
          $relPath = replaceExtension( $relPath, $extension_out_dev );
          $tmpStr = $includeString;

          $tmpStr =~ s/$REPLACE/$relPath/;
          printLog( "\tdev - including: $tmpStr" );
          print FILE $tmpStr."\n";

        }

      }

      print FILE $typeProps->{ postpend };
      close FILE;
    }


  }
}

sub moveToTarget {
  my ( $config, $filesByTypeAndDir, $workDir ) = @_;
  my $scratch = $config->{ folders }->{ scratch };
  my $bin = $config->{ folders }->{ build };
  my $build = $config->{ buildType };
  my $root = $config->{ root };
  my $doDeletes = $config->{ doDeletes };
  my $minPath;
  my $type;
  my $typeProps;
  my $buildFolder;
  my $ext;
  my $ext_out;
  my $fileName;
  my $file;
  my $minFile;
  my $finalFile;
  my $compressable;
  my @commands;
  my $rawcommand;
  my $command;

  if( File::Spec->file_name_is_absolute( $root ) ){
    $root = $root;
  } else {
    $root = File::Spec->catfile( $workDir, $root );
    $root = Cwd::realpath( $root );
  }


  $minPath = File::Spec->catdir( $scratch, $MIN );
  -e $minPath or mkdir $minPath or printLog( "Cannot make minPath: $minPath: $!" );

  foreach $type( keys %{ $filesByTypeAndDir } ){
    $typeProps = $config->{ typeProps }->{ $type };
    $ext = $typeProps->{ extension };
    $ext_out = $typeProps->{ extension_out } ? $typeProps->{ extension_out } : $ext;
    $buildFolder = $typeProps->{ build };
    if( $build eq $BUILD_TYPE_PROD ){
      @commands = ( $typeProps->{ production_commands } ) ? @{ $typeProps->{ production_commands } } : ();
    } else {
      @commands = ( $typeProps->{ development_commands } ) ? @{ $typeProps->{ development_commands } } : ();
    }

                if( ! defined $buildFolder || $buildFolder eq '' ) {
                    $buildFolder = File::Spec->catdir( $ext, $bin );
                }


    $buildFolder = File::Spec->catdir( $root, $buildFolder );

                # TODO:  Ensure all parents of the $buildFolder exist.  They may not.

    -e $buildFolder or File::Path::make_path( $buildFolder ) or croak "Cannot make buildFolder \"$buildFolder\": $!";

    if( $doDeletes ){
      printLog( "\temptying $buildFolder of $ext_out files" );
      emptyDirOfType( $buildFolder, $ext_out );
    }

    foreach $fileName ( keys %{ $filesByTypeAndDir->{ $type } } ){ #TODO: this iteration doesn't seem to be working

      $file = File::Spec->catfile( $scratch, "$fileName.$ext_out" );
      $minFile = File::Spec->catfile( $scratch, $MIN, "$fileName.$ext_out" );
      if(
        ( $build eq $BUILD_TYPE_PROD )
      ){
        copy( $file, $minFile ) or printLog( "Could not copy $file to $minFile: $!" );
#        printLog( "running production commands on file: $file" );
        foreach $rawcommand ( @commands ){
          $command = $rawcommand;
          printLog( "rawcommand: $command" );
          my $scriptPath = '{scriptsPath}';
          my $infile = '{infile}';
          my $outfile = '{outfile}';
          $command =~ s/$scriptPath/$Bin/g;
          $command =~ s/$infile/$minFile/g;
          $command =~ s/$outfile/$minFile/g;
          printLog( "trying $command" );
          `$command`;
        }
      } else {
        copy( $file, $minFile ) or printLog( "Could not copy $file to $minFile: $!" );
      }

      $finalFile = File::Spec->catfile( $buildFolder, "$fileName.$ext_out" );
      copy( $minFile, $finalFile ) or printLog( "Could not copy $minFile, to $finalFile: $!" );

      printLog("\tcreated $finalFile" );
    }
  }
}

sub doSourceCommands {
  printLog( "beginning source commands" );
  my ( $config, $workDir, $filesForSourceCommands ) = @_;
  my $root = $config->{ root };
  my $typeProps;
  my $doCommands;
  my $build = $config->{ buildType } || $BUILD_TYPE_PROD;
  my @files;
  my $ext;
  my @source_commands;
  my $command;
  my $filelist;

  my $scriptPath = '{scriptsPath}';
  my $filesVar = '{files}';
  my $rootVar = '{root}';


  if( File::Spec->file_name_is_absolute( $root ) ){
    $root = $root;
  } else {
    $root = File::Spec->catfile( $workDir, $root );
    $root = Cwd::realpath( $root );
  }

  for $ext ( keys %{ $filesForSourceCommands } ) {
    $typeProps = $config->{ typeProps }->{ $ext };
    @files = @{ $filesForSourceCommands->{ $ext } };
    $filelist = "@files";
    @source_commands = ( $typeProps->{ source_commands } ) ? @{ $typeProps->{ source_commands } } : ();
    $doCommands = $typeProps->{ do_source_commands } || "";
    if(
      $doCommands eq $build
    or  $doCommands eq "both"
    ){
      $doCommands = 1;
    } else {
      $doCommands = 0;
    }
    if( $doCommands ){
      foreach $command ( @source_commands ){

        $command =~ s/$scriptPath/$Bin/g;
        $command =~ s/$filesVar/$filelist/g;
        $command =~ s/$rootVar/$root/g;
        printLog( "  trying: $command" );
        `$command`;
      }
    }
  }

  printLog( "ending source commands" );
}

# sub doProdCommands {
#   printLog( "beginning production commands" );
#   my ( $config, $workDir ) = @_;
#   my $typeProps;
#   my $doCommands;
#   my $build = $config->{ buildType } || $BUILD_TYPE_PROD;
#   my @commands;
#   my $command;
#   my $scriptPathVar = '{scriptsPath}';
#   my $buildPathVar = '{buildPath}';

#   if( $build ne $BUILD_TYPE_PROD ){
#     return 0;
#   }

#   @commands = ( $config->{ prod }->{ commands } ) ? @{ $config->{ prod }->{ commands } } : ();
#   foreach $command ( @commands ){
#     $command =~ s/$scriptPathVar/$Bin/g;
#     $command =~ s/buildPathVar/$workDir/g;
#     printLog( "\ttrying: $command" );
#     `$command`;
#   }

#   printLog( "ending production commands" );
# }

sub normalizeConfigurationValues {
# Expects:
#   $config: The configuration hash reference.
#   $workDir: The current working directory.

    my $config = shift;
    my $workDir = shift || Cwd::getcwd();
    $config->{ workDir } = Cwd::abs_path( $workDir );

    # The only valid values are 'prod' ($BUILD_TYPE_PROD) and 'dev' ($BUILD_TYPE_DEV).
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


    

    return $config;
}

sub setUpResources {
# Expects:
#   $config: The configuration hash reference.

    my $config = shift;

    my $scratchDir = $config->{ folders }->{ scratch };


    unless( -e $scratchDir ) {
        mkdir $scratchDir, 0777 or croak "Cannot create scratch directory \"$scratchDir\": $!";
    }

    -w $scratchDir or croak "The scratch directory is not writable: $scratchDir";

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

  moveToTarget( $config, $filesByTypeAndDir, $config->{workDir} );

  cleanUpResources( $config );

  doSourceCommands( $config, $config->{workDir}, $filesForSourceCommands );

  logEnd( $config->{ buildType } );
}

1;
