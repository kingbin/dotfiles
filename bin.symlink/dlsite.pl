#!/usr/bin/perl
#
# curlmirror.pl
#
# Mirrors a web site by using curl to download each page.
# The result is stored in a directory named "dest" by default.
# Temporary files are stored in "/tmp".
#
# Author: Kjell.Ericson@haxx.se
#
# Limitations:
#   All links are right now based from the root, so there are a lot
#   of "../../" in pages.
#
# History:
#
# 1999-11-19 v0.9 - Kjell Ericson - First version
# 1999-11-22 v0.10 - Kjell Ericson - Added some more flags
# 1999-12-06 v0.11 - Kjell Ericson - Relative paths were not correctecd
# 1999-12-06 v1.0  - Kjell Ericson - Satisfied and updated to v1.0
# 1999-12-07 v1.1  - Kjell Ericson - Added "-p"
# 1999-12-08 v1.2  - Kjell Ericson - Added "-l" and "-c"
# 1999-12-13 v1.3  - Kjell Ericson - Added match for images in stylesheets
# 2000-08-07 v1.4  - Kjell Ericson - Handles both ' and " in links.
# 2000-08-15 v1.5  - Kjell Ericson - Added -I.
# 2000-08-16 v1.6  - Kjell Ericson - Added multiple -I and -B.
# 2002-01-23 v1.7  - Anthony Thyssen - Changed the destination filename
# 2002-07-14 v1.8  - Kjell Ericson - Corrected a temp-filename error
#
$max_deep=1000;
$max_size=2;

$dest_dir="dest";
$default_name="index.html";
$tmp="/tmp";
$filecounter=0;

# For faster handling we have this regex:
$nonhtmlfiles="jpg|gif|png|zip|doc|txt|pdf|exe|java|js|css";

$help=
    "Usage: curlmirror.pl [flags] [url]\n".
    "\n".
    "-a <args>  : Curl specific arguments\n".
    "-B <url>   : Only retrieve URL below this URL (default is [url]).\n".
    "-b <name>  : Pattern that will be stripped from filename.\n".
    "-c         : Ignore CGI's (i.e URL's with '?' in them) (default off).\n".
    "-d <number>: Depth to scan on (default unlimited).\n".
    "-f         : Flat directory structure is made (be careful).\n".
    "-F         : Flat directory structure but use path in filename.\n".
    "-i <name>  : Default name for unknown filenames (default is 'index.html').\n".
    "-I <regex> : Don't handle files matching this pattern (default is \"\".\n".
    "-l         : Only load HTML-pages - no images (default is to load all).\n".
    "-o <dir>   : Directory to output result in (default is 'dest').\n".
    "-s <number>: Max size in Mb of downloaded data (default 2 Mb)\n".
    "-p         : Always load images (default is not to).\n".
    "-t <dir>   : Temporary directory (default is '/tmp').\n".
    "-v         : Verbose output.\n".
    "\n".
    "Example:\n".
    "curlmirror.pl http://www.perl.com/\n".
    "\nAuthor: Kjell.Ericson\@haxx.se\n";

for ($i=0; $i<=$#ARGV; $i++) {
    $arg=$ARGV[$i];
    if ($arg =~ s/^-//) {
        if ($arg =~ m/\?/) {
            print $help;
            exit();
        }
        if ($arg =~ m/a/) {
            $curl_args=$ARGV[++$i];
        }
        if ($arg =~ m/B/) {
            $base=$ARGV[++$i];
            if ($base !~ m/(http:\/\/[^\/]*)/i) {
                print "***Malformed -B(ase)\n";
                die($help);
            }
            $base=~ s/([+*~^()\\])/\\$1/g; # escape chars
            push @basematch, $base;
        }
        if ($arg =~ m/I/) {
            push @ignorepatt, $ARGV[++$i];
        }
        if ($arg =~ m/b/) {
            $strip_from_file=$ARGV[++$i];
        }
        if ($arg =~ m/c/) {
            $ignore_cgi=1;
        }
        if ($arg =~ m/d/) {
            $max_deep=$ARGV[++$i];
        }
        if ($arg =~ m/o/) {
            $dest_dir=$ARGV[++$i];
            $dest_dir=~ s/\/$//g;
        }
        if ($arg =~ m/t/) {
            $tmp=$ARGV[++$i];
            $tmp=~ s/\/$//g;
        }
        if ($arg =~ m/s/) {
            $max_size=$ARGV[++$i];
        }
        if ($arg =~ m/i/) {
            $default_name=$ARGV[++$i];
        }
        if ($arg =~ m/l/) {
            $only_html=1;
        }
        if ($arg =~ m/v/) {
            $verbose=1;
        }
        if ($arg =~ m/p/) {
            $picture_load=1;
        }
        if ($arg =~ m/f/) {
            $flat=1;
        }
        if ($arg =~ m/F/) {
            $flat=2;
        }
    } else { #default
        $start=$arg;
    }
}

$curl="curl -s $curl_args ";

if ($base eq "") {
    if ($start !~ m/(http:\/\/.+\/)/i) {
        if ($start =~ m/(http:\/\/.+)/i) {
            $start.="/";
        } else {
            print "***Malformed start URL ($start)\n";
            die($help);
        }
    }
    $base=$start;
    $base=~ s/\/[^\/]+$/\//; # strip docname
    $base=~ s/([+*~^()\\])/\\$1/g; # escape chars
    $basematch[0]=$base;
}


$follow_link{"start"}=0;

$linktmp="[ \n\r]*=[ \r\n]*)([\"'][^\"']*[\"']|[^ )>]*)";
%follow=(
         "(<[^>]*a[^>]+href$linktmp", "link",
         "(<[^>]*area[^>]+href$linktmp", "link",
         "(<[^>]*frame[^>]+src$linktmp", "link",
         );
if ($only_html == 0) {
    %follow=(%follow,
             "(BODY[^>]*\{[^}>]*background-image:[^>}]*url[(])([^\}>\) ]+)", "img", # for stylesheets
             "(<[^>]*img[^>]+src$linktmp", "img",
             "(<[^>]*body[^>]+background$linktmp", "img",
             "(<[^>]*applet[^>]+archive$linktmp", "archive",
             "(<[^>]*td[^>]+background$linktmp", "img",
             "(<[^>]*tr[^>]+background$linktmp", "img",
             "(<[^>]*table[^>]+background$linktmp", "img",
             );
}

$deep=0;
$found=1;
while ($found && $deep<$max_deep) {
    $found=0;
    foreach $url (keys %follow_link) {
        $current_depth=$follow_link{$url};
#        print STDERR ">$url $current_depth\n";
        if ($current_depth == $deep && $current_depth>=0 &&
            $total_size<$max_size*1024*1024) {
            $found=1;
            $current_depth++;
            if ($url eq "start") {
                delete $follow_link{$url};
                $url=$start;
                $url="stdin" if ($url eq "");
                $start="";
            }
            $follow_link{$url}=-1;
            $stop=0;

            $status_code=0;
            $content_type="";
            $real_url=$url;
            $real_url=~s/#(.*)//; # strip bookmarks before loading
            if ( $url !~ m/[ \n\r]/) {
                $filecounter++;
                $this_file_name="$filecounter..$real_url";
                $this_file_name =~ s/%([a-fA-F0-9][a-fA-F0-9])/chr hex $1/eg;
                #$this_file_name=~ s/[^a-zA-Z0-9.]+/_/g;
                $this_file_name=~ s/[^\w\d]+/_/g;
                $content_type="";

                print STDERR "Get $deep:$url\n" if ($verbose);
                $head=`$curl -D - -o "$tmp/$this_file_name" "$real_url"`;
                $filenames{$real_url}=$this_file_name;
                if ($head =~ m/Location: *["]?(.*)["]?/i) {
                    $loc=$1;
                    $loc=~ s/[\r\n]//g;
                    $loc=merge_urls($real_url, $loc);
                    if (accept_url($loc) ||
                        ($picture_load && $linktype{$real_url} eq "img")) {
                        `rm "$tmp/$this_file_name"`;
                        delete $filenames{$real_url};
                        $real_url=$loc;
                        $url=$loc;
                        print STDERR "Reget $deep:$url\n" if ($verbose);
                        $head=`$curl -D - -o "$tmp/$this_file_name" "$real_url"`;
                        $filenames{$real_url}=$this_file_name;
                        $follow_link{$real_url}=-1;
                    }
                }
                $total_size+=-s "$tmp/$this_file_name";

                if ($head =~ m/^HTTP[^\n\r]* ([0-9]+) ([^\n\r]*)/s) {
                    $status_code=$1;#." ".$2;
                }
                if ($head =~ m/[\n\r]Content-Type:(.*)[\r\n]/si) {
                    $content_type=$1;
                }
                $linktype{$real_url}=$content_type;
                if ($content_type !~ m/html/i) {
                    if ($only_html) { # remove this file
                        $total_size-=-s "$tmp/$this_file_name";
                        `rm "$tmp/$this_file_name"`;
                        delete $filenames{$real_url};
                    }
                } else {
                    $text=`cat "$tmp/$this_file_name"`;
                    if ($current_depth<$max_deep) {
                        $linktype{$real_url}="html";
                        $text="" if ($url =~ m/\#/);
                        foreach $search (keys %follow) {
                            while ($text =~ s/$search//si) {
                                $link=$2;
                                $link=~ s/[\"\']//g;
                                $link=~ s/#.*//;
                                $newurl=merge_urls($url, $link);
                                if ($ignore_cgi==0 || $newurl !~ m/\?/) {
                                    if (accept_url($newurl) ||
                                        ($picture_load && $follow{$search} eq "img")) {
                                        if (!exists $follow_link{$newurl}) {
                                            if ($only_html == 0 ||
                                                $newurl !~ m/\.($nonhtmlfiles)$/i) {
                                                $follow_link{$newurl}=$current_depth;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    $deep++;
}
print STDERR "Max size exceeded ($total_size bytes)!\n" if ($total_size>=$max_size*1024*1024);
print STDERR "Total size loaded:$total_size bytes\n" if ($verbose);

foreach $url (keys %filenames) {
    local $destname=$url;
    $destname=~ s/$basematch[0]//;
    local $destdir=$destname;

    $destdir="" if ($destdir !~ m/\//);
    $destdir =~ s/\/[^\/]*$/\//;

    $destname=~ s/^.*\///g;
    $destname=~s/#(.*)//;
    local $bookmark=$1;

    $destname=~ s/[^a-zA-Z0-9.]/_/g; # strip chars we don't want in a filename
    $destdir=~ s/$strip_from_file// if ($strip_from_file ne "");
    $destdir=~ s/^([^\/]+):\/\//$1_/;
    $destdir=~ s/[^a-zA-Z0-9.\/_]/_/g;
    $destdir=~ s/(^\/)|(\/$)//g; # strip trailing/leading slashes

    if ($flat) {
        if ($flat==2) {
            $destdir=~ s/[\/:]/_/g;
            $destdir.="_";
        } else {
            $destdir="";
        }
        `mkdir -p "$dest_dir"`;
    } else {
        local $tmp="$dest_dir/$destdir";
        $tmp=~ s/^\///g;
        `mkdir -p "$tmp"`;
        $destdir.="/" if ($destdir ne "");
    }
    $destname=$default_name if ($destname eq "");
    $destname=$destdir.$destname if ($destdir ne "");
    if (($linktype{$url} =~ m/html/i) && ($destname !~ m/\.[s]?htm/i)) {
        $destname.=".html";
    }
    $destfile{$url}=$destname;
}

foreach $url (keys %filenames) {
    $name=$filenames{$url};
    $destname=$destfile{$url};

    if ($linktype{$url} !~ m/html/) {
        `mv "$tmp/$name" "$dest_dir/$destname"`;
    } else {
        $text=`cat "$tmp/$name"`;
        foreach $search (keys %follow) {
            $text=~ s/$search/"$1\"".make_file_relative($url,merge_urls($url, $2))."\""/sgie;
        }
        if (open(OUT, ">$dest_dir/$destname")) {
            print OUT $text;
            close(OUT);
        } else {
            print STDERR "Couldn't save file '$dest_dir/$destname'\n";
        }
        `rm "$tmp/$name"`;
    }
}

# Input: Base-URL, MakeRelative-URL
#
# Function: Convert and return "MakeRelativ-URL" to be relative
# to "Base-URL".
#
sub make_file_relative
{
    local ($from, $to)=@_;
    local $result="";
    local $sourcename=$destfile{$from};
    local $destname;
    local $bookmark;


    if ($to=~ s/(\#.*)$//) { # extract bookmarks
        $bookmark=$1;
    }

    $destname=$destfile{$to};

    if ($destname eq "") {
        return $to.$bookmark
    }


    $sourcename="" if ($sourcename !~ m/\//);

    $sourcename=~ s/\/[^\/]*$/\//; #strip filename
    do {
        $sourcename=~ m/^([^\/]*\/)/;
        local $dir=$1;
        if ($dir ne "") {
            $dir=~ s/([*.\\\/\[\]()+|])/\\$1/g;
            if ($destname =~ s/^$dir//) {
                $sourcename=~ s/^$dir//;
            } else {
                $dir="";
            }
        }
    } while ($dir ne "");
    $sourcename=~ s/[^\/]+\//..\//g; # Relative it with some ../

    $result="$sourcename$destname";
    $result=~ s/^\///g;

    return $result.$bookmark;
}


# Function: If you are viewing location "$base" which is a full URL, and
# click on "$new" that can be full or relative - where do you get? That
# is what this function returns.
#
# Input: base-URL, new-URL (where to go)
# Returns: a full format new-URL (without bookmark)
#
sub merge_urls
{
    local ($org, $new)=@_;
    local $url, $new;

    $new =~ s/[\"\']//g;

    if ($new =~ m/.*:/) {
        $url=$new;
    } elsif ($new eq "") {
        $url=$org;
    } else {
        if ($org =~ m/(.*):\/\/([^\/]*)(.*)$/) {
            local $prot=$1;
            local $server=$2;
            local $pathanddoc=$3;
            local $path;
            local $doc=$3;
            if ($pathanddoc=~ m/^(.*)\/(.*)$/) {
                $path=$1;
                $doc=$2;
            }
            $doc=~s/#(.*)//;
            local $bookmark=$1;

            if ($new =~ m/^#/) {
                $url="$prot://$server$path/$doc$new";
            } elsif ($new =~ m/^\//) {
                $url="$prot://$server$new";
            } else {
                $url="$prot://$server$path/$new";
                while ($url =~ s/\/[^\/]*\/\.\.\//\//){}
                while ($url =~ s/\.\///){};
            }
        }

    }
    return $url;
}

sub accept_url
{
    local ($url)=@_;
    local $ret=0;
    print "test  $url\n";
    for (@basematch) {
        if ($url =~ m/$_/) {
            $ret=1;
        }
    }
    return 0 if ($ret == 0); # No basematch

    for (@ignorepatt) {
        if ($url =~ m/$_/) {
            return 0;
        }
    }
    print "match $url\n";
    return 1;
}
