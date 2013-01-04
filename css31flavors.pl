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

use Carp;
use Cwd;
use FindBin qw();
use lib "$FindBin::Bin/lib";

use strict;
use warnings;

use File::Basename;
use File::Find;
use File::Spec;
use IO::File;
use POSIX qw();

# Constants

use constant {
  MAX   => 31
, TRUE  => 1
, FALSE => ''
, HORIZ_LINE => '=' x 32
};

my $IMPORT_PATTERN = qr/^\@import/;

# Stuff happens after here.

# Are we really going to do stuff?
$main::forReals = TRUE;

# Where are we going to do stuff?
my @targetDirs = ();

# Process command-line arguments
for( @ARGV ) {
  if( $_ eq '-n' ) {
    $main::forReals = FALSE;
    next;
  }

  unless( -d $_ ) {
    carp "'$_' is not a directory.  Skipping.";
    next;
  }

  push @targetDirs, $_;
}

logThis(
  HORIZ_LINE
, "Begin $0 : " . formattedTime()
);

if( scalar @targetDirs == 0 ) {
  push @targetDirs, Cwd::getcwd();
}

logThis( 'Target directories: ' . join( ':', @targetDirs ) );

# Set up list storage for CSS filenames.
my @cssFilePaths = ();

# Define a subroutine reference for doing something with CSS files.
my $cssFilePathSnarfer = getWantedSub( qr/\.css$/, \@cssFilePaths ); 

# Populate @cssFilePaths.
for my $targetDir ( @targetDirs ) {
  find( $cssFilePathSnarfer, $targetDir );
}
@cssFilePaths = sort @cssFilePaths;


# Iterate over every CSS file.
for my $cssFilePath ( @cssFilePaths ) {

  my( $cssFilename, $cssDir, $suffix ) = fileparse( $cssFilePath, qr/\Q.css\E/ );
  
  my $cssHandle = IO::File->new( $cssFilePath, 'r' );
  unless( defined $cssHandle ) {
    carp "Unable to open '$cssFilePath' for reading. Skipping.";
    next;
  }

  my @lines = <$cssHandle>;

  # Close the original CSS file.
  undef $cssHandle;

  # Classify lines
  my @importLines = ();
  my @nonImportLines = ();
  for( @lines ) {
    if( /$IMPORT_PATTERN/ ) {
      push @importLines, $_;
    }
    else {
      push @nonImportLines, $_;
    }
  }

  logThis( "CSS file path: $cssFilePath [" . (scalar @importLines) . '/' . (scalar @nonImportLines) . ']'  );

  # Do we need to rewrite the CSS file?
  if( scalar @importLines > MAX ) {
    
    # If $cssDir is not writable, we cannot continue..
    unless( -w $cssDir ) {
      croak "Unable to replace files in '$cssDir': not writable.";
    }

    # How many subfiles will we need?
    my $subFileCount = POSIX::ceil( ( scalar @importLines ) / MAX );

    logThis( ( scalar @importLines ) . ' > ' . MAX . ": replacement file and $subFileCount subfiles needed" );

    # Create the file that will replace the original.
    my $tempFilePath = File::Spec->catfile( $cssDir, "$cssFilename.tmp.css" );
    my $tempHandle = IO::File->new( ( $main::forReals ? $tempFilePath : File::Spec->devnull() ), 'w' );
    unless( defined $tempHandle ) {
      croak "Unable to open '$tempFilePath' for writing: $!";
    }
    logThis( "Created temp replacement file: '$tempFilePath'" );


    for my $subFileIndex ( 0 .. ( $subFileCount - 1 ) ) {

      # Zero-pad the index value.
      if( $subFileIndex < 10 ) {
        $subFileIndex = '0' . $subFileIndex; # Zero-padding
      }

      # Create the subfile that will hold up to MAX imports from the original parent.
      my $subFileName = "${cssFilename}_sub_${subFileIndex}.css";
      my $subFilePath = File::Spec->catfile( $cssDir, $subFileName );
      my $subHandle = IO::File->new( ( $main::forReals ? $subFilePath : File::Spec->devnull() ), 'w' );
      unless( defined $subHandle ) {
        croak "Unable to open '$subFilePath' for writing: $!";
      }
      logThis( 'Created subfile ' . ( $subFileIndex + 1 ) . ": '$subFilePath'" );

      # If MAX is 31, the ranges will be 0..31, 32..63, 64..95, etc.
      for my $importLineIndex ( ( $subFileIndex * MAX ) .. ( ( ( $subFileIndex + 1 ) * MAX ) - 1 ) ) {
        # The last subfile will likely not run all the way to the end.
        if( $importLineIndex > $#importLines ) {
          last;
        }
        my $importLine = $importLines[$importLineIndex];
        
        $subHandle->print( $importLine );
        chomp $importLine;
        logThis( "Adding subfile import: ${importLine}" );
      }

      # Close the subfile.
      undef $subHandle;

      # Write the subfile import into the replacement parent.
      my $parentImportLine = "\@import url(\"${subFileName}\");";
      $tempHandle->print( $parentImportLine . $/ );
      logThis( "Adding replacement file import: ${parentImportLine}" );

    }

    # Write the non-import lines below the new subfile import lines.
    for my $nonImportLine ( @nonImportLines ) {
      $tempHandle->print( $nonImportLine );
    }
    logThis( 'Wrote remaining non-import lines to the replacement file.' );

    # Close the temporary file.
    undef $tempHandle;
    
    # Replace the original CSS file with the replacement.
    if( $main::forReals ) {
      unless( rename $tempFilePath, $cssFilePath ) {
        croak "Unable to rename '$tempFilePath' to '$cssFilePath': $!";
      }

      logThis( "Renamed '$tempFilePath' to '$cssFilePath'." );
    }

  }
  else {
    logThis( ( scalar @importLines ) . ' <= ' . MAX . ": Skip this file." );
  }

  logThis( '' );

}

logThis(
  "End $0 : " . formattedTime()
, HORIZ_LINE
);

sub getWantedSub {
  my $pattern = shift;
  my $arrayRef = shift;

  return sub {
    if( /$pattern/ ) {
      push @{$arrayRef}, $File::Find::name;
    }
  }
}

sub logThis {
  local $, = $/; # Used to join elements in @_.
  local $\ = $/; # Used at the end of the print.

  print { $main::forReals ? *STDOUT : *STDERR } @_;
}

sub formattedTime {
  return POSIX::strftime( '%m/%d/%Y %H:%M:%S', localtime );
}

