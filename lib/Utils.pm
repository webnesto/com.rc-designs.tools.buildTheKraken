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

package Utils;

#Includes
use strict;
use warnings;

use Carp;
use File::Spec;
use IO::File;
use POSIX;
use JSON;

our @ISA = qw(Exporter);
our @EXPORT = qw(
  printLog
  extend
  extendNew
  from_json_file
  emptyDirOfType
  replaceVariables
);

# get index of item in array
sub indexOf {
  my ($item, $array_ref) = @_;
  $array_ref->[$_] eq $item && return $_ for 0..$#$array_ref; 
  return undef;
}


sub printLog {
#  print POSIX::strftime("%m/%d/%Y %H:%M:%S", localtime).":\n";
  print " $_$/" for @_;
}

sub extend {
  # Expects a list of hash-refs.  The key-value pairs of the first referenced hash
  # will be extended with key-value pairs of the subsequent ones.

  my $base_hashref = shift;
  croak "All arguments to extend() must be hash-refs." unless ref( $base_hashref ) eq 'HASH';
  for my $extension_hashref ( @_ ) {
    croak "All arguments to extend() must be hash-refs." unless ref( $extension_hashref ) eq 'HASH';
    for my $extension_key ( keys %{$extension_hashref} ) {
      my $baseValue = $base_hashref->{ $extension_key }; # May not be defined.
      my $extension_value = $extension_hashref->{ $extension_key };

      if( ( ref( $baseValue ) eq 'HASH' ) && ( ref( $extension_value ) eq 'HASH' ) ) {
        # If both the values are hash-refs, call extend recursively on them.
        extend( $baseValue, $extension_value );
      }
      else {
        # Otherwise, replace the $baseValue with the $extension_value.
        $base_hashref->{ $extension_key } = $extension_value;
      }

    }
  }

  return $base_hashref;
}

sub extendNew {
  my $base_hashref = {};

  extend( $base_hashref, $_ ) for @_;

  return $base_hashref;
}

#sub openConfigObj {
sub from_json_file {
  my $file = shift;
  my $json = "";

  if( -r $file ){
    printLog( "Getting hashref from JSON file: $file" );

    my $fh = new IO::File( $file, 'r' );
    croak "Cannot open file for reading: $file" unless defined $fh;;

    while ( <$fh> ) {
      chomp;
      s/(?<![":])\/\/.*(?!")$//;  # remove single line comments
      s/\"false\"/0/;             # don't bother with values set to "false"
      $json .= $_;
    }
    close $fh;

    return from_json $json;
  }
  else {
    # The file doesn't exist or is not readable.
    # We'll return an empty hashref.
    return {};
  }
}

sub emptyDirOfType {
  my ( $dir, $extension ) = @_;
  my @files;

  carp "'$dir' is not a directory.  Cannot remove contents." and return 0 unless -d $dir;
  carp "'$dir' is not writable.  Cannot remove contents." and return 0 unless -w $dir;

  for( glob File::Spec->catfile( $dir, "*.$extension" ) ) {
    unlink or carp "Could not unlink $_: $!";
  }

}

sub replaceVariables {
  my $contentString = shift || '';
  my %replacements = %{ shift || {} };

  $contentString =~ s,\$\{([^}]+)},$replacements{$1},g;
  
  return $contentString;
}

1;
