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
use Utils qw( printLog );

# Constants

use constant {
  MAX => 31
};




# Stuff happens after here.

printLog(
  "++++++++++++++++"
, "begin css31flavors: " . POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime)
);

# Where are we now?
my $originalDir = Cwd::getcwd();

# Where are we going to do stuff?
my $targetDir = Cwd::abs_path( shift || '.' );

printLog( "target directory is $targetDir" );

# Set up list storage for CSS filenames.
my @cssFilePaths;

# Define a subroutine reference for doing something with CSS files.
my $cssFilePathSnarfer = getWantedSub( qr/\.css$/, \@cssFilePaths );

# Go to the target directory.
#chdir $targetDir;

# Populate @cssFilePaths.
find( $cssFilePathSnarfer, $targetDir );

for my $path ( @cssFilePaths ) {

  printLog( "full path : $path" );

  my( $filename, $directories, $suffix ) = fileparse( $path, qr/\Q.css\E/ );
  
  printLog(
    "basename  : $basename"
  , "directory : $directories"
  , "suffix    : $suffix"
    );

  my $fh = new IO::File $path, 'r';
  unless( defined $fh ) {
    carp "Unable to open '$path' for reading. Skipping.";
    next;
  }

  my @lines = <$fh>;
  my @imports = grep { /^\@import/ } @lines;

  printLog( "Import count: ". scalar @imports  );

  if( scalar @imports > MAX ) {
    printLog( ( scalar @imports ) . " > " . MAX . ': Creating subsets' );
  }

}

exit 0;


foreach $css_file (@css_files) {
  printLog( "file: $css_file" );
  my($filename, $directories, $suffix) = fileparse($css_file, qr/\Q.css\E/);

  printLog( "filename is: $filename" );

  open FILE, "<$css_file";
  my @lines = <FILE>;
  @imports = ();

  foreach $line (@lines){
    if( $line =~ /^\@import/ ){
      push( @imports, $line );
    }
  }

  $imports = @imports;

  printLog( "has this many imports: $imports" );

  if( $imports > $MAX ){
    printLog( "creating subsets" );
    $import_count = 0;
    $file_count = 0;

    $tmpfile = File::Spec->catfile( $targetDir,  "$filename.tmp.css" );
    open TMPFILE, ">$tmpfile";

    &startSubfile(
      $subfile
    , $targetDir
    , $filename
    , $file_count
    );

    foreach $import  (@imports) {
      print FILEPART $import;
      $import_count = $import_count + 1;
      if( $import_count == $MAX ){
        $import_count = 0;
        close FILEPART;
        $file_count = $file_count + 1;
        &startSubfile(
          $subfile
        , $targetDir
        , $filename
        , $file_count
        );
      }
    }

    close FILEPART;
    close TMPFILE;
  } else {
    $tmpfile = 0;
  }


  close FILE;
  if( $tmpfile ){
    rename $tmpfile, $css_file;
  }
}

printLog(
  "end css31flavors:"
.  POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime)
, "++++++++++++++++"
);

sub startSubfile {
  my (
    $subfile
  , $targetDir
  , $filename
  , $file_count
  ) = @_;

  $subfile = File::Spec->catfile( $targetDir,  "$filename"."_"."$file_count.css" );
  printLog( "sub file: $subfile" );
  open FILEPART, ">$subfile";
  print TMPFILE "\@import \"$filename"."_"."$file_count.css\";\n";
}

