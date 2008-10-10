package HTML::ExtractContent;
use strict;
use warnings;
use HTML::ExtractContent::Util;
use List::Util qw(reduce);
use utf8;
use base qw(Class::Accessor::Lvalue::Fast);
our $VERSION = '0.01';
__PACKAGE__->mk_accessors(qw(opt content));

sub new {
    my ($class, $opt) = @_;
    my $self = $class->SUPER::new($opt);
    $self->opt = {
        threshold          => 50,   # threhold for score of clusters
        min_length         => 30,   # minimum length of blocks
        decay_factor       => 0.75, # decay factor for block scores
        no_body_factor     => 0.72,
        continuous_factor  => 1.62, # continuous factor for block scores
        punctuation_weight => 10,   # score weight for punctuations

        punctuations => qr/([。、．，！？]|\.[^A-Za-z0-9]|,[^0-9]|!|\?)/is,
        waste_expressions => qr/Copyright|All\s*Rights?\s*Reserved?/is,
            # characteristic keywords including footer
        affiliate_expressions =>
            qr/amazon[a-z0-9\.\/\-\?&]+-22/is,
        block_separator => qr/<\/?(?:div|center|td)[^>]*>|<p\s*[^>]*class\s*=\s*["']?(?:posted|plugin-\w+)['"]?[^>]*>/is,
#         nocontent => qr/<\/frameset>|<meta\s+http-equiv\s*=\s*["']?refresh['"]?[^>]*url/is,
        nocontent => qr/<\/frameset>/is,
        min_nolink => 8,
        nolist_ratio => 0.2,
        debug => 0
    };
    $self->{pattern} = {
        a        => qr/<a\s[^>]*>.*?<\/a\s*>/is,
        href     => qr/<a\s+href\s*=\s*(['"]?)([^"'\s]+)\1/is,
        list     => qr/(ul|dl|ol)(.+)<\/\1>/is,
        li       => qr/(<li[^>]*>|<dd[^>]*>)/is,
        title    => qr/<title[^>]*>(.*?)<\/title\s*>/is,
        headline => qr/(<h\d\s*>\s*(.*?)\s*<\/h\d\s*>)/is,
        head     => qr/<head[^>]*>.*?<\/head\s*>/is,
        comment  => qr/<!--.*?-->/is,
        special  => qr/<![A-Za-z].*?>/is,
        useless  => [ qr/<(script|style|select|noscript)[^>]*>.*?<\/\1\s*>/is,
                      qr/<div\s[^>]*(id|class)\s*=\s*['"]?\S*(more|menu|side|navi)\S*["']?[^>]*>/is,
                  ],
    };
    return bless $self, $class;
}

sub as_text {
    my $self = shift;
    return to_text $self->content;
}

sub as_html {
    my $self = shift;
    return $self->content;
}

sub extract {
    my $self = shift;;
    $self->content = shift;
    if ($self->content =~ $self->opt->{nocontent}) {
        # frameset or redirect
        $self->content = '';
        return $self;
    }
    $self->_extract_title;
    $self->_eliminate_head;

    $self->_eliminate_useless_symbols;
    $self->_eliminate_useless_tags;

    my ($factor, $continuous);
    $factor = $continuous = 1.0;
    my $body = '';
    my $score = 0;
    my @list = split $self->opt->{block_separator}, $self->content;
    my $best = {
        content => "",
        score => 0,
    };
    push @list, ""; # dummy
    my $c = 0;
    for my $block (@list) {
        if ($c > $self->opt->{threshold}) {
            print "\n**", $score, "\n" if $self->opt->{debug};
            if ($score > $best->{score}) {
                $best = {
                    content => $body,
                    score => $score,
                };
            }
            $body = $block . "\n";
            $score = $c;
            $continuous = $self->opt->{continuous_factor};
        }

        $block = strip $block;
        next unless decode $block;
        $continuous /= $self->opt->{continuous_factor} if length $body;

        # ignore link list block
        my $nolink = $self->_eliminate_links($block);
        my $nolinklen = length $nolink;
        next if $nolinklen < $self->opt->{min_length};

        # score
        $c = $self->_score($nolink, $factor);
        $factor *= $self->opt->{decay_factor};

        # anti-scoring factors
        my $no_body_rate = $self->_no_body_rate($block);

        $c *= ($self->opt->{no_body_factor} ** $no_body_rate);
        my $c1 = $c * $continuous;

        print "---- $c*$continuous=$c1 $nolinklen\n$block\n"
            if $self->opt->{debug};

        # cluster scoring
        if ($c1 > $self->opt->{threshold}) {
            $body .= $block . "\n";
            $score += $c1;
            $continuous = $self->opt->{continuous_factor};
        }
    }
    print "\n**", $score, "\n" if $self->opt->{debug};
    $self->content = $best->{content};

    return $self;
}

sub _score {
    my ($self, $nolink, $factor) = @_;
    return ((length $nolink)
                + (match_count $nolink, $self->opt->{punctuations})
                    * $self->opt->{punctuation_weight})
        * $factor;
}

sub _no_body_rate {
    my ($self, $block) = @_;
    return (match_count $block,$self->opt->{waste_expressions})
        + (match_count $block,$self->opt->{affiliate_expressions})/2.0;
}

sub _extract_title {
    my $self = shift;
    my $title;
    if ($self->content =~ $self->{pattern}->{title}) {
        $title = strip (strip_tags $1);
        if (length $title) {
            my $pat = $self->{pattern}->{headline};
            $self->content =~ s/$pat/
                (index "$2", $title) >= 0 ? "<div>$2<\/div>" : "$1"/igse;
        }
    }
}

sub _eliminate_head {
    my $self = shift;
    my $pat = $self->{pattern}->{head};
    $self->content =~ s/$pat//is;
}

sub _eliminate_useless_symbols {
    my $self = shift;
    my $comment = $self->{pattern}->{comment};
    my $special = $self->{pattern}->{special};
    $self->content =~ s/$comment//igs;
    $self->content =~ s/$special//igs;
}

sub _eliminate_useless_tags {
    my $self = shift;
    my @useless = @{$self->{pattern}->{useless}};
    for my $pat (@useless) {
        $self->content =~ s/$pat//igs;
    }
}

sub _eliminate_links {
    my ($self, $block) = @_;
    my $count = match_count $block, $self->{pattern}->{a};
    my $nolink = to_text (eliminate_forms (eliminate_links $block));
    return '' if length $nolink < $self->opt->{min_nolink} * $count;
    return '' if $self->_is_linklist($block);
    return $nolink;
}

sub _is_linklist {
    my ($self, $block) = @_;
    my $listpat = $self->{pattern}->{list};
    if ($block =~ $listpat) {
        my $list = $2;
        my $nolist = $block;
        $nolist =~ s/$listpat//igs;
        $nolist = to_text $nolist;
        my @listitems = split $self->{pattern}->{li}, $list;
        shift @listitems;
        my $rate = 0;
        for my $li (@listitems) {
            $rate++ if $li =~ $self->{pattern}->{href};
        }
        $rate = 1.0 * $rate / ($#listitems+1) if $#listitems+1;
        $list = to_text $list;
        my $limit = ($self->opt->{nolist_ratio}*$rate)
            * ($rate * (length $list));
        return length $nolist < $limit;
    }
    return 0;
}

1;
__END__

=head1 NAME

HTML::ExtractContent - An HTML content extractor with scoring heuristics

=head1 SYNOPSIS

 use HTML::ExtractContent;
 use LWP::UserAgent;
 
 my $agent = LWP::UserAgent->new;
 my $res = $agent->get('http://www.example.com/');
 
 my $extractor = HTML::ExtractContent->new;
 $extractor->extract($res->decoded_content);
 print $extractor->as_text;

=head1 DESCRIPTION

HTML::ExtractContent is a module for extracting content from HTML with scoring
heuristics. It guesses which block of HTML looks like content according to
scores depending on the amount of punctuation marks and the lengths of non-tag
texts. It also guesses whether content end in the block or continue to the
next block.

=head1 METHODS

=over 4

=item new

 $extractor = HTML::ExtractContent->new;

Creates a new HTML::ExtractContent instance.

=item extract

 $extractor->extract($html);

Extracts content from C<$html>.
C<$html> must have its UTF-8 flag on.

=item as_text

 $extractor->extract($html)->as_text;

Returns extracted content as a plain text. All tags are eliminated.

=item as_html

 $extractor->extract($html)->as_html;

Returns extracted content as an HTML text.
Note that the returned text is neither fully tagged nor valid HTML.
It doesn't contain tags such as <html> and it may have block tags that are
not closed, or closed but not opened.
This method is intended for the case that you need to analyze link tags in
the text for example.

=back

=head1 ACKNOWLEDGEMENT

Hiromichi Kishi contributed toward development of this module
as a partner of pair programming.

Implementation of this module is based on the Ruby module ExtractContent by Nakatani Shuyo.

=head1 AUTHOR

INA Lintaro <tarao at cpan.org>

=head1 COPYRIGHT

Copyright (C) 2008 INA Lintaro / Hatena. All rights reserved.

=head2 Copyright of the original implementation

Copyright (c) 2007/2008 Nakatani Shuyo / Cybozu Labs Inc. All rights reserved. 

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 SEE ALSO

L<http://rubyforge.org/projects/extractcontent/>
