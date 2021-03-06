#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use 5.10.0;
use Data::Dumper;
use Readonly;
use HTML::TreeBuilder::XPath;
use HTML::TreeBuilder::LibXML;
use HTML::Entities qw(:DEFAULT encode_entities_numeric);
use LWP::ConnCache; 
use LWP::UserAgent;
use LWP::Protocol::Net::Curl;
use CGI::Fast;
use Encode;
use POSIX qw(strftime);

binmode STDOUT, 'utf8';
binmode STDIN, 'utf8';

HTML::TreeBuilder::LibXML->replace_original();

Readonly my $BASEURL    => 'https://twitter.com';

my $URL = $ENV{'OWN_BASEURL_USER'};
if ( not defined $URL ) {
  $URL = 'http://twitrss.me/twitter_user_to_rss';
}
Readonly my $OWNBASEURL => $URL;

my $browser = LWP::UserAgent->new;
$browser->agent('Opera/9.80 (Windows NT 6.1; WOW64) Presto/2.12.388 Version/12.18');

# From http://lwp.interglacial.com/ch11_01.htm#perllwp-CHP-11-SECT-1
# Enables cookies
$browser->cookie_jar( {} );

$browser->conn_cache(LWP::ConnCache->new(5));
$browser->timeout(2);

while (my $q = CGI::Fast->new) {
        my @ps = $q->param; 
        my $bad_param=0;
        for(@ps) {
          unless ($_=~/^(fetch|replies|user)$/) {
            err("Bad parameters. Naughty.",404); 
            $bad_param++;
            last;
          }
        } 
        next if $bad_param;

  my $user = $q->param('user') || 'ciderpunx';

  $user = lc $user;
  if($user =~ '^#') {
    err("That was an hashtag, TwitRSS.me only supports users!",404); 
    next;
  }
  $user=~s/(@|\s|\?)//g;
  $user=~s/%40//g;

  my $max_age=3600;

  my $replies = $q->param('replies') || 0;
  if ($replies && lc($replies) ne 'on') {
          err("Bad parameters. Naughty.",404); 
          $bad_param++;
          next;
  }

  my $url = "$BASEURL/$user";
  $url .= "/with_replies" if $replies;

  # Clear cookies before every request.
  $browser->cookie_jar( {} );
  my $response = $browser->get($url);
  unless ($response->is_success) {
    err('Can&#8217;t screenscrape Twitter',404);
    next;
  }
  my $content = $response->content;


  my @items;

  my $tree= HTML::TreeBuilder::XPath->new;
  $tree->parse($content);

  my $feedavatar = $tree->findvalue('//img' . class_contains("ProfileAvatar-image") . "/\@src");

  # Get capitalization from Twitter page
  my $normalizedName = $tree->findvalue('//a' . class_contains("ProfileHeaderCard-screennameLink") . "/\@href");
  $normalizedName =~ s{^/}{};
  $user = $normalizedName;

  my $tweets = $tree->findnodes( '//li' . class_contains('js-stream-item')); # new version 2015-06-02

  if ($tweets) {
    for my $li (@$tweets) {    
      my $tweet = $li->findnodes('./div' 
                                  . class_contains("js-stream-tweet") 
                                )->[0]
      ;
      next unless $tweet;
      # die $tweet->as_HTML;
      my $header = $tweet->findnodes('./div/div' 
                                     . class_contains("stream-item-header") 
                                     . "/a" 
                                     . class_contains("js-action-profile"))->[0];
      my $bd   = $tweet->findnodes( './div/div/p' 
                                     . class_contains("js-tweet-text")
                                     )->[0];
      my $body = "<![CDATA[" . encode_entities($bd->as_HTML,'^\n\x20-\x25\x27-\x7e"') . "]]>";
      $body=~s{&amp;(\w+);}{&$1;}gi;
      $body=~s{<a}{ <a}gi; # always spaces before a tags
      $body=~s{href="/}{href="https://twitter.com/}gi; # add back in twitter.com to unbreak links to hashtags, users, etc.
      # Fix pic.twitter.com links.
      $body =~ s{href="https://t\.co/[A-Za-z0-9]+">(pic\.twitter\.com/[A-Za-z0-9]+)}{href="https://$1">$1</a>}g;
      $body=~s{<a[^>]+href="https://t.co[^"]+"[^>]+title="([^"]+)"[^>]*>}{ <a href="$1">}gi;      # experimental! stop links going via t.co; if an a has a title use it as the href.
      $body=~s{<a[^>]+title="([^"]+)"[^>]+href="https://t.co[^"]+"[^>]*>}{ <a href="$1">}gi;      # experimental! stop links going via t.co; if an a has a title use it as the href.
      $body=~s{target="_blank"}{}gi;
      $body=~s{</?s[^>]*>}{}gi;
      $body=~s{data-[\w\-]+="[^"]+"}{}gi; # validator doesn't like data-aria markup that we get from twitter
      $body=~s{<img.*?alt="(.+?)"[^>]*>}{$1}gi;
      my $avatar = $header->findvalue('./img' . class_contains("avatar") . "/\@src"); 
      my @fst_img_a = $tweet->findnodes( './div//div'
                                       . class_contains("js-adaptive-photo")
                                       );
      ## Need a test case for old media
      @fst_img_a = $tweet->findnodes( './div/div'
                                    . class_contains("OldMedia")
                                    . "/div/div") unless @fst_img_a;

      my $fst_img="";
      foreach my $img_a (@fst_img_a) {
        if($img_a) {
          $fst_img = $img_a->findvalue('@data-image-url');
          if($fst_img) {
            $body=~s{\]\]>$}{" <img src=\"$fst_img\" width=\"250\" />\]\]>"}e;
          }
        }
      }
      my $video = $tweet->findnodes('./div//div'
                                    . class_contains("PlayableMedia-player")
                                   )->[0];
      if($video) {
        $video = $video->findvalues('@style')->[0]; # url of video is derived from the background image used as placeholder
        $video =~ s{[^']+'([^']+)'\)}{$1};
        if ($video =~ m{tweet_video} ) {
          $video =~ s{https://pbs.twimg.com/tweet_video_thumb/([a-zA-Z0-9_]+).jpg}{https://video.twimg.com/tweet_video/$1.mp4};
          $body =~ s{\]\]>$}{" <video src=\"$video\" width=\"250\" loop>Your browser does not support the video tag.</video>\]\]>"}e;
        }
#        elsif ($video =~ m{ext_tw}) {
#          # TODO : cannot deal with these videos, so do nothing for now
#          # the url is requested by JS code and need authentication
#        }
      }

      my $fullname = $header->findvalue('./strong' . class_contains("fullname"));
      my $username = $header->findvalue('./span' . class_contains("username"));
      $username =~ s{<[^>]+>}{}g;
      $username =~ s{^\s+}{};
      $username =~ s{\s+$}{};
      foreach my $img ($bd->findnodes('.//img')) {
       $img->replace_with($img->attr('alt'));
      }
      my $title = enctxt($bd->as_text);
      $title=~s{&nbsp;}{}gi;
      $title=~s{http}{ http}; # links in title lose space
      my $uri = $BASEURL . $tweet->findvalue('@data-permalink-path');  
      my $timestamp = $tweet->findnodes('./div/div'
                      . class_contains("stream-item-header")
                      . '/small/a' 
                      . class_contains("tweet-timestamp"))->[0]->findvalue('./span/@data-time'
      );  

      my $pub_date = strftime("%a, %d %b %Y %H:%M:%S %z", localtime($timestamp));

      push @items, {
        username => enctxt($username),
        fullname => enctxt($fullname),
        link => $uri,
        guid => $uri,
        title => $title,
        description => $body,
        timestamp => $timestamp,
        pubDate => $pub_date,
      }
    }
  }
  else {
    $tree->delete; 
    err("Can't gather tweets for that user",404);
    next;
  }
  $tree->delete; 

  # now print as an rss feed, with header
print<<ENDHEAD
Content-type: application/rss+xml
Cache-control: public, max-age=$max_age
Access-Control-Allow-Origin: *

<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:georss="http://www.georss.org/georss" xmlns:twitter="http://api.twitter.com" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <atom:link href="$OWNBASEURL/?user=$user" rel="self" type="application/rss+xml" /> 
    <title>Twitter Search / $user </title>
    <link>https://twitter.com/$user</link>
    <description>Twitter feed for: $user. Generated by TwitRSS.me</description>
    <language>en-us</language>
    <ttl>40</ttl>
    <image>
        <url>$feedavatar</url>
    </image>
ENDHEAD
;

for (@items) {
  print<<ENDITEM
    <item>
      <title>$_->{title}</title>
      <dc:creator>$_->{fullname} ($_->{username})</dc:creator>
      <description>$_->{description}</description>
      <pubDate>$_->{pubDate}</pubDate>
      <guid>$_->{guid}</guid>
      <link>$_->{link}</link>
      <twitter:source/>
      <twitter:place/>
    </item>
ENDITEM
;
}

print<<ENDRSS
  </channel>
</rss>      
ENDRSS
;
}

sub enctxt {
  my $text=shift;
  encode_entities_numeric(decode_entities($text));
}
sub class_contains {
  my $classname = shift;
  "[contains(concat(' ',normalize-space(\@class),' '),' $classname ')]";
}

sub err {
  my ($msg,$status) = (shift,shift);
  print<<ENDHEAD
Content-type: text/html
Status: $status
Cache-control: max-age=86400
Refresh: 10; url=http://twitrss.me

<html><head></head><body><h2>ERR: $msg</h2><p>Redirecting you back to <a href="http://twitrss.me">TwitRSS.me</a> in a few seconds. You might have spelled the username wrong or something</p></body></html>
ENDHEAD
;
}
