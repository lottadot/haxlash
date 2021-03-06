#!/usr/bin/perl -w
# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.

package Slash::Tagbox::Top;

=head1 NAME

Slash::Tagbox::Top - update the top n tags on a globj

=head1 SYNOPSIS

	my $tagbox_tcu = getObject("Slash::Tagbox::Top");
	my $feederlog_ar = $tagbox_tcu->feed_newtags($tags_ar);
	$tagbox_tcu->run($affected_globjid);

=cut

use strict;

use Slash;

our $VERSION = $Slash::Constants::VERSION;

use base 'Slash::Tagbox';

sub init_tagfilters {
	my($self) = @_;

	$self->{filter_activeonly} = 1;
	$self->{filter_publiconly} = 1;

	# Not interested in tags on sf.net project globjs.
	my $types = $self->getGlobjTypes();
	$self->{filter_gtid} = [
		map { $types->{$_} }
		grep { $_ !~ /^\d+$/ && $_ ne 'projects' }
		keys %$types ];
}

sub get_affected_type	{ 'globj' }
sub get_clid		{ 'describe' }
sub get_userchanges_regex { qr{^tag_clout$} }

sub feed_newtags_process {
	my($self, $tags_ar) = @_;
	my $constants = getCurrentStatic();

	my $ret_ar = [ ];
	for my $tag_hr (@$tags_ar) {
		# affected_id and importance work the same whether this is
		# "really" newtags or deactivatedtags.
		my $days_old = (time - $tag_hr->{created_at_ut}) / 86400;
		my $importance =  $days_old <  1	? 1
				: $days_old < 14	? 1.1**-$days_old
				: 1.1**-14;
		my $ret_hr = {
			affected_id =>	$tag_hr->{globjid},
			importance =>	$importance,
		};
		if ($tag_hr->{tdid})	{ $ret_hr->{tdid}  = $tag_hr->{tdid}  }
		else			{ $ret_hr->{tagid} = $tag_hr->{tagid} }
		push @$ret_ar, $ret_hr;
	}

	return $ret_ar;
}

sub run_process {
	my($self, $affected_id, $tags_ar) = @_;
	my $constants = getCurrentStatic();
	my $tagsdb = getObject('Slash::Tags');
	my $tags_reader = getObject('Slash::Tags', { db_type => 'reader' });

	my($type, $target_id) = $tagsdb->getGlobjTarget($affected_id);

	# Get the list of tags applied to this object.  If we're doing
	# URL popularity, that's only the tags within the past few days.
	# For stories, it's all tags.

	my $options = { };
	if ($type eq 'urls') {
		my $days_back = $constants->{bookmark_popular_days} || 3;
		$options->{days_back} = $days_back;
	}
	$tagsdb->addCloutsToTagArrayref($tags_ar);

	# Generate the space-separated list of the top 5 scoring tags.

	# Now set the data accordingly.  For a story, set the
	# tags_top field to that list.

	# Using the total_clout calculated in addCloutsToTagArrayref(),
	# and counting opposite tags against ordinary tags, calculate
	# %scores, the hash of tagnames and their scores.  Note that
	# due to the presence of opposite tags, there may be many
	# entries in %scores with negative values.

	my $describe = $self->getCloutTypes()->{describe};
	my %scores_orig = ( );
	my %count_orig = ( );
	for my $tag (@$tags_ar) {
		$scores_orig{$tag->{tagnameid}} += $tag->{total_clout};
		$count_orig {$tag->{tagnameid}} ++;
	}

	# XXX doublecheck this logic

	# This consolidates scores:  if both "foo" and "!foo" have been
	# tagged, their scores are totaled counting against each other
	# (each's score will be the negative of the other).

	my $scores = $tagsdb->consolidateTagnameidValues(\%scores_orig, $describe);

	# Since $abs is set, this consolidates counts, so that if both
	# "foo" and "!foo" are set to 1, each will end up with a score
	# of 2.

	my $counts = $tagsdb->consolidateTagnameidValues(\%count_orig,  $describe,
		{ abs => 1 });

	# Eliminate tagnames in a given list, and their opposites.
	my $exclude_hr = { };
	my $exclude_ar = $tagsdb->getExcludedTagnameids();
	for my $tnid (@$exclude_ar) {
		$exclude_hr->{$tnid} = 1;
	}
	my $exclude_opposite_hr = $tagsdb->consolidateTagnameidValues($exclude_hr, $describe,
		{ invert => 1, posonly => 1 });
	for my $tnid (keys %$exclude_opposite_hr) {
		$exclude_hr->{$tnid} = 1;
	}
	for my $tnid (keys %$exclude_hr) {
		$scores->{$tnid} = 0 if $scores->{$tnid};
	}

	# Eliminate tagnames that are just the author's name.
	my @names = @{ $tags_reader->getAuthorNames() };
	my @name_ids = grep { $_ } map { $tagsdb->getTagnameidFromNameIfExists(lc $_) } @names;
	for my $tnid (@name_ids) {
		$scores->{$tnid} = 0 if $scores->{$tnid};
	}

	my $author_regex_str = join '|', @names;
	my $author_prefix_regex = qr{^($author_regex_str)};
	for my $tnid (keys %$scores) {

		# Tagnames that begin with an author's name are half as likely
		# to appear on the homepage.
		my $tagname = $tagsdb->getTagnameDataFromId($tnid)->{tagname};
		$scores->{$tnid} *= 0.5 if $tagname =~ $author_prefix_regex;

		# Long tagnames are less likely to appear on the homepage.
		my $l = length($tagname);
		next if $l <= 8;
		my $length_mod = 1;
		if ($l <= 12) {
			# 8 < length <= 12, very mild penalty
			$length_mod = 1.00 + (1.00-0.90)*( 8 - $l)/(12- 8);
		} elsif ($l <= 30) {
			# 12 < length <= 30, increasing penalty
			$length_mod = 0.90 + (0.90-0.25)*(12 - $l)/(30-12);
		} elsif ($l <= 40) {
			# 30 < length <= 40, severe penalty
			$length_mod = 0.25 + (0.25-0.05)*(30 - $l)/(40-30);
		} else {
			# 40 < length <= 64, very severe penalty (REALLY hard
			# to get these on the homepage)
			$length_mod = 0.05 + (0.05-0.01)*(40 - $l)/(64-40);
		}
		$scores->{$tnid} *= $length_mod;
	}

	# Eliminate the domaintag for (XXX) this website.
	my $domain_tnid = $constants->{mainpage_nexus_tid};
	$scores->{$domain_tnid} &&= 0;

	# Eliminate tagnames below the minimum score required, and
	# those that didn't make it to the top 5
	# XXX the "4" below (aka "top 5") is hardcoded currently, should be a var
	my $minscore1 = $constants->{tagbox_top_minscore_urls};
	my $minscore2 = $constants->{tagbox_top_minscore_stories};

	my $tndata = $tagsdb->getTagnameDataFromIds([keys %$scores]);

	my $plugin = getCurrentStatic('plugin');
	if ($plugin->{FireHose}) {
		my $firehose = getObject('Slash::FireHose');
		my $fhid = $firehose->getFireHoseIdFromGlobjid($affected_id);
		my @top = ( );
		if ($fhid) {
			@top =  map { $tndata->{$_}{tagname} }
				grep { $scores->{$_} >= 0 }
				grep { $scores->{$_} >= $minscore1 }
				sort {
					$scores->{$b} <=> $scores->{$a}
					||
					$tndata->{$a}{tagname} cmp $tndata->{$b}{tagname}
				} keys %$scores;
			$#top = 4 if $#top > 4;
			$firehose->setFireHose($fhid, { toptags => join(' ', @top) });
			$self->info_log("%d with %d tags, setFireHose %d to '%s' >= %d",
				$affected_id, scalar(@$tags_ar), $fhid, join(' ', @top), $minscore1);
		}
	}

	if ($type eq 'stories') {

		my @top = map { $tndata->{$_}{tagname} }
			grep { $scores->{$_} >= 0 }
			grep { $scores->{$_} >= $minscore2 }
			sort {
				$scores->{$b} <=> $scores->{$a}
				||
				$tndata->{$a}{tagname} cmp $tndata->{$b}{tagname}
			} keys %$scores;
		$#top = 4 if $#top > 4;
		$self->setStory($target_id, { tags_top => join(' ', @top) });
		main::tagboxLog("Top->run $affected_id with " . scalar(@$tags_ar) . " tags, setStory $target_id to '@top'");

	} elsif ($type eq 'urls') {

		# For a URL, calculate a numeric popularity score based
		# on (most of) its tags and store that in the popularity
		# field.
		#
		# (I think this code is obsolete...? - Jamie 2006/11/29)
		# (it's still being run, but urls.popularity is not the
		# same value as firehose.popularity, and I'm not sure if
		# the former is being used anywhere - Jamie 2008/06/17)

		my %tags_pos = map { $_, 1 } split(/\|/, $constants->{tagbox_top_urls_tags_pos} || "");
		my %tags_neg = map { $_, 1 } split(/\|/, $constants->{tagbox_top_urls_tags_neg} || "");

		my $pop = 0;
		for my $tag (@$tags_ar) {
			my $tagname = $tag->{tagname};
			my $is_pos = $tags_pos{$tagname};
			my $is_neg = $tags_neg{$tagname};
			my $mult = 1;
			$mult =  1.5 if $is_pos && !$is_neg;
			$mult = -1.0 if $is_neg && !$is_pos;
			$mult =  0   if $is_pos &&  $is_neg;
			$pop += $mult * $tag->{total_clout};
		}

		$self->setUrl($target_id, { popularity => $pop });
		main::tagboxLog("Top->run $affected_id with " . scalar(@$tags_ar) . " tags, setUrl $target_id to pop=$pop");

	}

}

1;

