#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use feature qw/say/;
use Encode;
use Data::Dumper;
use LWP::UserAgent;
use File::Copy;
use XML::RSS;
use XML::Simple;
use Term::ProgressBar;
use WWW::NicoVideo::Download;
use MP3::Tag;
use Web::Scraper;
use Term::ReadKey;

my $account = {
    mail => '',
    password => '',
};

my $env = {
    encoder     => "ffmpeg",
    tmp_dir     => "tmp/",
    mp3_dir     => "mp3/",
    mp3_rate    => '192k',
    mylist_id   => '',
};

my $nico_url = {
    login        => "https://secure.nicovideo.jp/secure/login?site=niconico",
    getthumbinfo => "http://ext.nicovideo.jp/api/getthumbinfo/",
    mylist       => "http://www.nicovideo.jp/mylist/",
    watch        => "http://www.nicovideo.jp/watch/",
    thumb_img    => "http://tn-skr3.smilevideo.jp/smile?i=", 
                        # following value is video_id without sm/nm.
};

my $console;
if ($^O =~ /MSWin32/) {
    print "stdout encoding: cp932\n";
    $console = find_encoding("cp932");
}
else {
    print "stdout encoding: utf-8\n";
    $console = find_encoding("utf-8");
}

# INIT

print "mylist URL: http://www.nicovideo.jp/mylist/";
ReadMode(0);
$env->{mylist_id} = ReadLine(0);
$env->{mylist_id} =~ s/[\r\n]//g;

mkdir("./$env->{tmp_dir}") unless (-d "./$env->{tmp_dir}");
mkdir("./$env->{mp3_dir}") unless (-d "./$env->{mp3_dir}");
mkdir("./$env->{tmp_dir}/$env->{mylist_id}") unless (-d "$env->{tmp_dir}$env->{mylist_id}");
mkdir("./$env->{mp3_dir}/$env->{mylist_id}") unless (-d "$env->{mp3_dir}$env->{mylist_id}");

print "E-mail : ";
ReadMode(0);
$account->{mail} = ReadLine(0);
$account->{mail} =~ s/[\r\n]//g;

print "Password : ";
ReadMode('noecho');
$account->{password} = ReadLine(0);
$account->{password} =~ s/[\r\n]//g;
ReadMode 0;

my $downloader = WWW::NicoVideo::Download->new(
    email    => $account->{mail},
    password => $account->{password},
);
say "\n\nLogin...";
exit unless $downloader->login('sm9');

my $ua = LWP::UserAgent->new( cookie_jar => $downloader->user_agent->cookie_jar );

my ($mylist_title, @video_list) = get_video_url_list($env->{mylist_id});

my $total_file = scalar @video_list;
print $console->encode("Download $total_file files.\n\n");

while (@video_list) {
    my $video_url = shift @video_list;
    my $separator = "\n" . '*' x 15;

    say $console->encode('*' x 30 . " Processing [ " . ($total_file - $#video_list - 1) . " / $total_file ]");

    my $video_id = $1 if ($video_url =~ /watch\/(\w+)$/gm);

    my $internal_id;
    ($video_id =~ /^\d/) 
        ? $internal_id = resolve_id($video_id) 
        : $internal_id = $video_id
    ;

    my $video_info = get_video_info($internal_id);

    say $console->encode("$separator Downloading: $video_info->{video_title}");
    my $flv_path = save_flv($video_id);

    say $console->encode("$separator Encoding: $video_info->{video_title} ($flv_path)");
    $flv_path = cwf2fws($flv_path) if ($flv_path =~ /x-shockwave-flash$/);
    system($env->{encoder}, '-i', $flv_path, '-ab', $env->{mp3_rate}, "$flv_path.mp3");

    say $console->encode("$separator Encoded: $video_info->{video_title} ($flv_path)");
    write_ID3v2_tag("$flv_path.mp3", $video_info);
    copy("$flv_path.mp3", "$env->{mp3_dir}$env->{mylist_id}/$video_id.mp3");

    if (@video_list) {
        say "\nwait 10sec...\n";
        sleep 10;
    }
}

say 'Complete!';

exit;

sub write_ID3v2_tag {
    my ($mp3_path, $video_info) = @_;

    my $pic = $ua->get( $video_info->{thumb_img} )->{_content};

    MP3::Tag->config('write_v24' => 1);
    my $mp3 = MP3::Tag->new($mp3_path);
    $mp3->get_tags;

    my $id3v2;
    (exists $mp3->{ID3v2}) 
        ? $id3v2 = $mp3->{ID3v2}
        : $id3v2 = $mp3->new_tag('ID3v2');
    ;

    # TIT2 : Title/songname/content description 
    # TALB : Album/Movie/Show title 
    # TOPE : Original artist(s)/performer(s) 
    # APIC : Attached picture Keys: MIME type, Picture Type, Description, _Data

    $id3v2->add_frame("TIT2", $video_info->{video_title});
    $id3v2->add_frame("TALB", $mylist_title);
    $id3v2->add_frame("APIC", "image/jpeg", "Cover (front)", 'Thumbnail', $pic);

    $id3v2->write_tag;
}

sub cwf2fws {
    # See also http://zefonseca.com/cws2fws/release/cws2fws
    my $flv_path = shift;
    my ($zlib_data, $header, $type_sig, $unc, $file_prefix, $outfile);
    
    say $console->encode("Uncompressing: $flv_path\nPlease wait...");

    use Compress::Zlib;
    $file_prefix = $flv_path;
    open(my $fil, "<", $flv_path) or die $!;
    binmode $fil; # for windows
    read($fil, $type_sig, 3, 0);

    # is case sensitive, bytes must match ASCII 0x43 0x57 0x53 ("CWS" )
    die "Flash file is not compressed(CWS) or header is invalid.\n" if ($type_sig eq 'FWS');

    # reads last bytes of header
    read($fil, $header, 5, 0);

    # filehandle pointer now at 8 bytes offset. the rest of the file is zlib compressed data
    while (<$fil>) {
        $zlib_data .= $_;
    }
    close $fil;

    $unc = uncompress($zlib_data);
    $outfile = $flv_path . ".mp4";
    open(my $zil, ">", $outfile) or die $!;
    binmode $zil; # for windows
    print {$zil} "FWS" . $header . $unc;
    close $zil;

    return $outfile;
}

sub save_flv {
    my $video_id = shift;
    my ($term, $fh, $flv_path);

    $downloader->download($video_id,
        sub {
            my ($data, $res, $proto) = @_;
            unless ($term && $fh) {
                my $ext = (split '/', $res->header('Content-Type'))[-1] || 'flv';
                $flv_path = "$env->{tmp_dir}$env->{mylist_id}/$video_id.$ext";
                open $fh, ">", $flv_path or die $!;
                binmode $fh;
                $term = Term::ProgressBar->new( $res->header('Content-Length') );
            }
            $term->update( $term->last_update + length $data );
            print {$fh} $data;
        }
    );

    return $flv_path;
}

sub get_video_info {
    my $internal_id = shift;
    
    my $res = $ua->get($nico_url->{watch} . $internal_id)->decoded_content;
    my $scraper = scraper { process 'h1', 'video_title' => 'TEXT'; };

    my $video_info = {};
    $video_info = $scraper->scrape($res);

    $video_info->{thumb_img} = $nico_url->{thumb_img} . $1
        if ($internal_id =~ /(\d+)$/);

    return $video_info;
}

sub resolve_id {
    my $external_id = shift;
    
    my $body = $ua->get($nico_url->{watch} . $external_id)->decoded_content;

    ($body =~ /www\.nicovideo\.jp\/tag_edit\/(\w+)'/gm)
        ? return $1
        : die "cannot resolve internal ID. Try again."
    ;
}

sub get_video_url_list {
    my $id  = shift;
    my $url = $nico_url->{mylist};
    my @url_list;

    ($id =~ /^(\d+)/) ? $url .= "$1?rss=2.0" : die "Invalid mylist URL";

    print "Fetching RSS...\n\n";

    my $parsed_rss = XML::RSS->new->parse( $ua->get($url)->decoded_content );

    print $console->encode('*' x 10 . " $parsed_rss->{channel}->{title} " . '*' x 10 . "\n\n");

    for my $item ( @{$parsed_rss->{items}} ) {
        push @url_list, $item->{'link'};
    }

    return $parsed_rss->{channel}->{title}, @url_list;
}

1;
__END__

