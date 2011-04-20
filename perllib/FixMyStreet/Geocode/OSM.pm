#!/usr/bin/perl
#
# FixMyStreet:Geocode::OSM
# OpenStreetmap forward and reverse geocoding for FixMyStreet.
#
# Copyright (c) 2011 Petter Reinholdtsen. Some rights reserved.
# Email: pere@hungry.com

package FixMyStreet::Geocode::OSM;

use warnings;
use strict;

use mySociety::Config;
use LWP::Simple;
use XML::Simple;

my $osmapibase    = "http://www.openstreetmap.org/api/";
my $nominatimbase = "http://nominatim.openstreetmap.org/";


sub lookup_location {
    my ($latitude, $longitude, $zoom) = @_;
    my $url =
    "${nominatimbase}reverse?format=xml&zoom=$zoom&lat=$latitude&lon=$longitude";
    my $j = LWP::Simple::get($url);
    if ($j) {
        my $ref = XMLin($j);
        return $ref;
    } else {
        print STDERR "No reply from $url\n";
    }
    return undef;
}

sub get_object_tags {
    my ($type, $id) = @_;
    my $url = "${osmapibase}0.6/$type/$id";
    my $j = LWP::Simple::get($url);
    if ($j) {
        my $ref = XMLin($j);
        my %tags;
        map { $tags{$_->{'k'}} = $_->{'v'} } @{$ref->{$type}->{tag}};
        return \%tags;
    } else {
        print STDERR "No reply from $url\n";
    }
    return undef;
}

sub guess_road_operator {
    my $inforef = shift;
    my $highway = $inforef->{highway} || "unknown";
    my $ref =  $inforef->{ref} || "unknown";

    my $operator;
    if ( mySociety::Config::get('COUNTRY') eq 'NO' ) {
        if ($highway eq "trunk"
            || $highway eq "primary"
            || $ref =~ m/E \d+/
            || $ref =~ m/Fv\d+/i
            ) {
            $operator = "Statens vegvesen";
        }
    }
    return $operator;
}

sub get_nearest_road_tags {
    my ($latitude, $longitude) = @_;
    my $inforef = lookup_location($latitude, $longitude, 16);
    if ('way' eq $inforef->{result}->{osm_type}) {
        my $osmtags = get_object_tags('way',
                                      $inforef->{result}->{osm_id});
        if (mySociety::Config::get('OSM_GUESS_OPERATOR')
            && !exists $osmtags->{operator}) {
            my $guess = guess_road_operator($osmtags);
            $osmtags->{operatorguess} = $guess if $guess;
        }
        return $osmtags;
    }
    return undef;
}

1;