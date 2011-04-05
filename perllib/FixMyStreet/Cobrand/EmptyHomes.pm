package FixMyStreet::Cobrand::EmptyHomes;
use base 'FixMyStreet::Cobrand::Default';

use strict;
use warnings;

use FixMyStreet;
use mySociety::Locale;
use Carp;

=item

Return the base url for this cobranded site

=cut

sub base_url {
    my $base_url = FixMyStreet->config('BASE_URL');
    if ( $base_url !~ /emptyhomes/ ) {
        $base_url =~ s/http:\/\//http:\/\/emptyhomes\./g;
    }
    return $base_url;
}

sub admin_base_url {
    return 'https://secure.mysociety.org/admin/emptyhomes/';
}

sub area_types {
    return qw(DIS LBO MTD UTA LGD COI);    # No CTY
}

=item set_lang_and_domain LANG UNICODE

Set the language and text domain for the site based on the query and host. 

=cut

sub set_lang_and_domain {
    my ( $self, $lang, $unicode, $dir ) = @_;
    my $set_lang = mySociety::Locale::negotiate_language(
        'en-gb,English,en_GB|cy,Cymraeg,cy_GB', $lang );
    mySociety::Locale::gettext_domain( 'FixMyStreet-EmptyHomes', $unicode,
        $dir );
    mySociety::Locale::change();
    return $set_lang;
}

=item site_title

Return the title to be used in page heads

=cut 

sub site_title {
    my ($self) = @_;
    return _('Report Empty Homes');
}

=item feed_xsl

Return the XSL file path to be used for feeds'

=cut

sub feed_xsl {
    my ($self) = @_;
    return '/xsl.eha.xsl';
}

1;
