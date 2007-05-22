package Slim::Control::Queries;

# $Id:  $
#
# SlimServer Copyright (c) 2001-2006  Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Queries

=head1 DESCRIPTION

L<Slim::Control::Queries> implements most SlimServer queries and is designed to 
 be exclusively called through Request.pm and the mechanisms it defines.

 Except for subscribe-able queries (such as status and serverstatus), there are no
 important differences between the code for a query and one for
 a command. Please check the commented command in Commands.pm.

=cut

use strict;

use Scalar::Util qw(blessed);
use URI::Escape;

use Slim::Utils::Misc qw(specified);
use Slim::Utils::Alarms;
use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

my $log = logger('control.queries');

my $prefs = preferences('server');

sub alarmsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['alarms']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $filter	 = $request->getParam('filter');
	my $alarmDOW = $request->getParam('dow');
	
	
	if ($request->paramNotOneOfIfDefined($filter, ['all', 'defined', 'enabled'])) {
		$request->setStatusBadParams();
		return;
	}
	
	my @results;

	if (defined $alarmDOW) {

		$results[0] = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);

	} else {

		my $i = 0;

		$filter = 'enabled' if !defined $filter;

		for $alarmDOW (0..7) {

			my $alarm = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);
			
			my $wanted = ( 
				($filter eq 'all') ||
				($filter eq 'defined' && !$alarm->undefined()) ||
				($filter eq 'enabled' && $alarm->enabled())
			);

			$results[$i++] = $alarm if $wanted;
		}
	}

	my $count = scalar @results;

	$request->addResult('fade', $client->prefGet('alarmfadeseconds'));
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'alarms_loop';
		my $cnt = 0;
		
		for my $eachitem (@results[$start..$end]) {
			$request->addResultLoop($loopname, $cnt, 'dow', $eachitem->dow());
			$request->addResultLoop($loopname, $cnt, 'enabled', $eachitem->enabled());
			$request->addResultLoop($loopname, $cnt, 'time', $eachitem->time());
			$request->addResultLoop($loopname, $cnt, 'volume', $eachitem->volume());
			$request->addResultLoop($loopname, $cnt, 'url', $eachitem->playlist());
			$request->addResultLoop($loopname, $cnt, 'playlist_id', $eachitem->playlistid());
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub albumsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['albums']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags');
	my $search        = $request->getParam('search');
	my $compilation   = $request->getParam('compilation');
	my $contributorID = $request->getParam('artist_id');
	my $genreID       = $request->getParam('genre_id');
	my $trackID       = $request->getParam('track_id');
	my $year          = $request->getParam('year');
	my $sort          = $request->getParam('sort');
			
	if ($request->paramNotOneOfIfDefined($sort, ['new', 'album'])) {
		$request->setStatusBadParams();
		return;
	}

	if (!defined $tags) {
		$tags = 'l';
	}
	
	# get them all by default
	my $where = {};
	my $attr = {};
	
	# Normalize and add any search parameters
	if (defined $trackID) {
		$where->{'tracks.id'} = $trackID;
		push @{$attr->{'join'}}, 'tracks';
	}
	
	# ignore everything if $track_id was specified
	else {
	
		if ($sort && $sort eq 'new') {

			$attr->{'order_by'} = 'tracks.timestamp desc, tracks.disc, tracks.tracknum, tracks.titlesort';
			push @{$attr->{'join'}}, 'tracks';
		}
		
		if (specified($search)) {
			$where->{'me.titlesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
		}
		
		if (defined $year) {
			$where->{'me.year'} = $year;
		}
		
		# Manage joins
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$compilation = 1;
			}
			else {	
				$where->{'contributorAlbums.contributor'} = $contributorID;
				push @{$attr->{'join'}}, 'contributorAlbums';
				$attr->{'distinct'} = 1;
			}			
		}
	
		if (defined $genreID){
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'tracks' => 'genreTracks'};
			$attr->{'distinct'} = 1;
		}
	
		if (defined $compilation) {
			if ($compilation == 1) {
				$where->{'me.compilation'} = 1;
			}
			if ($compilation == 0) {
				$where->{'me.compilation'} = [ { 'is' => undef }, { '=' => 0 } ];
			}
		}
	}
	
	# use the browse standard additions, sort and filters, and complete with 
	# our stuff
	my $rs = Slim::Schema->rs('Album')->browse->search($where, $attr);

	my $count = $rs->count;

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'albums_loop';
		my $cnt = 0;

		for my $eachitem ($rs->slice($start, $end)) {
			$request->addResultLoop($loopname, $cnt, 'id', $eachitem->id);
			$tags =~ /l/ && $request->addResultLoop($loopname, $cnt, 'album', $eachitem->title);
			$tags =~ /y/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'year', $eachitem->year);
			$tags =~ /j/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'artwork_track_id', $eachitem->artwork);
			$tags =~ /t/ && $request->addResultLoop($loopname, $cnt, 'title', $eachitem->rawtitle);
			$tags =~ /i/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'disc', $eachitem->disc);
			$tags =~ /q/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'disccount', $eachitem->discc);
			$tags =~ /w/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'compilation', $eachitem->compilation);
			if ($tags =~ /a/) {
				my @artists = $eachitem->artists();
				$request->addResultLoopIfValueDefined($loopname, $cnt, 'artist', $artists[0]->name());
			}
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub artistsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['artists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $year     = $request->getParam('year');
	my $genreID  = $request->getParam('genre_id');
	my $trackID  = $request->getParam('track_id');
	my $albumID  = $request->getParam('album_id');

	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'order_by' => 'me.namesort',
		'distinct' => 'me.id'
	};
	
	# same for the VA search
	my $where_va = {'me.compilation' => 1};
	my $attr_va = {};

 	# Normalize any search parameters
 	if (specified($search)) {
 
 		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
 	}

	my $rs;

	# Manage joins 
	if (defined $trackID) {
		$where->{'contributorTracks.track'} = $trackID;
		push @{$attr->{'join'}}, 'contributorTracks';
		
		# don't use browse here as it filters VA...
		$rs = Slim::Schema->rs('Contributor')->search($where, $attr);
	}
	else {
		if (defined $genreID) {
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'contributorTracks' => {'track' => 'genreTracks'}};
			
			$where_va->{'genreTracks.genre'} = $genreID;
			push @{$attr_va->{'join'}}, {'tracks' => 'genreTracks'};
		}
		
		if (defined $albumID || defined $year) {
		
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
				
				$where_va->{'me.id'} = $albumID;
			}
			
			if (defined $year) {
				$where->{'track.year'} = $year;
				
				$where_va->{'track.year'} = $year;
			}
			
			if (!defined $genreID) {
				# don't need to add track again if we have a genre search
				push @{$attr->{'join'}}, {'contributorTracks' => 'track'};

				# same logic for VA search
				if (defined $year) {
					push @{$attr->{'join'}}, 'track';
				}
			}
		}
		
		# use browse here
		$rs = Slim::Schema->rs('Contributor')->browse->search($where, $attr);
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

#	my $rs = Slim::Schema->rs('Contributor')->browse->search($where, $attr);

	
	# Various artist handling. Don't do if pref is off, or if we're
	# searching, or if we have a track
	my $count_va = 0;

	if ($prefs->get('variousArtistAutoIdentification') &&
		!defined $search && !defined $trackID) {

		# Only show VA item if there are any
		$count_va =  Slim::Schema->rs('Album')->search($where_va, $attr_va)->count;
	}

	my $count = $rs->count + ($count_va?1:0);

	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid || $count) {

		my $loopname = 'artists_loop';
		my $cnt = 0;

		# Various artist handling. Don't do if pref is off, or if we're
		# searching, or if we have a track
		if ($count_va) {
			my $vaObj = Slim::Schema->variousArtistsObject;

			$request->addResultLoop($loopname, $cnt, 'id', $vaObj->id);
			$request->addResultLoop($loopname, $cnt, 'artist', $vaObj->name);
			$cnt++;
		}

		for my $eachitem ($rs->slice($start, $end)) {
			$request->addResultLoop($loopname, $cnt, 'id', $eachitem->id);
			$request->addResultLoop($loopname, $cnt, 'artist', $eachitem->name);
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub cursonginfoQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['duration', 'artist', 'album', 'title', 'genre',
			'path', 'remote', 'current_title']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client = $request->client();

	# get the query
	my $method = $request->getRequest(0);
	my $url = Slim::Player::Playlist::url($client);
	
	if (defined $url) {

		if ($method eq 'path') {
			
			$request->addResult("_$method", $url);

		} elsif ($method eq 'remote') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::isRemoteURL($url));
			
		} elsif ($method eq 'current_title') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::getCurrentTitle($client, $url));

		} else {

			my $track = Slim::Schema->rs('Track')->objectForUrl($url);

			if (!blessed($track) || !$track->can('secs')) {

				logBacktrace("Couldn't fetch object for URL: [$url] - skipping track.");

			} else {

				if ($method eq 'duration') {

					$request->addResult("_$method", $track->secs() || 0);

				} elsif ($method eq 'album' || $method eq 'artist' || $method eq 'genre') {

					$request->addResult("_$method", $track->$method->name || 0);

				} else {

					$request->addResult("_$method", $track->$method() || 0);
				}
			}
		}
	}

	$request->setStatusDone();
}


sub connectedQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['connected']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	$request->addResult('_connected', $client->connected() || 0);
	
	$request->setStatusDone();
}


sub debugQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $category = $request->getParam('_debugflag');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $categories = Slim::Utils::Log->allCategories;
	
	if (defined $categories->{$category}) {
	
		$request->addResult('_value', $categories->{$category});
		
		$request->setStatusDone();

	} else {

		$request->setStatusBadParams();
	}
}


sub displayQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	my $parsed = $client->parseLines($client->curLines());

	$request->addResult('_line1', $parsed->{line}[0] || '');
	$request->addResult('_line2', $parsed->{line}[1] || '');
		
	$request->setStatusDone();
}


sub displaynowQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['displaynow']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_line1', $client->prevline1());
	$request->addResult('_line2', $client->prevline2());
		
	$request->setStatusDone();
}


sub genresQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['genres']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $search        = $request->getParam('search');
	my $year          = $request->getParam('year');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	# Normalize and add any search parameters
	if (specified($search)) {

		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
	}

	# Manage joins
	if (defined $trackID) {
			$where->{'genreTracks.track'} = $trackID;
			push @{$attr->{'join'}}, 'genreTracks';
	}
	else {
		# ignore those if we have a track. 
		
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$where->{'album.compilation'} = 1;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'album'}};
			}
			else {	
				$where->{'contributorTracks.contributor'} = $contributorID;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'contributorTracks'}};
			}
		}
	
		if (defined $albumID || defined $year){
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
			}
			if (defined $year) {
				$where->{'track.year'} = $year;
			}
			push @{$attr->{'join'}}, {'genreTracks' => 'track'};
		}
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	my $rs = Slim::Schema->resultset('Genre')->browse->search($where, $attr);

	my $count = $rs->count;

	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'genres_loop';
		my $cnt = 0;

		for my $eachitem ($rs->slice($start, $end)) {
			$request->addResultLoop($loopname, $cnt, 'id', $eachitem->id);
			$request->addResultLoop($loopname, $cnt, 'genre', $eachitem->name);
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub infoTotalQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['info'], ['total'], ['genres', 'artists', 'albums', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity = $request->getRequest(2);

	if ($entity eq 'albums') {
		$request->addResult("_$entity", Slim::Schema->count('Album'));
	}

	if ($entity eq 'artists') {
		$request->addResult("_$entity", Slim::Schema->rs('Contributor')->browse->count);
	}

	if ($entity eq 'genres') {
		$request->addResult("_$entity", Slim::Schema->count('Genre'));
	}

	if ($entity eq 'songs') {
		$request->addResult("_$entity", Slim::Schema->rs('Track')->browse->count);
	}
	
	$request->setStatusDone();
}


sub linesperscreenQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['linesperscreen']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_linesperscreen', $client->linesPerScreen());
	
	$request->setStatusDone();
}


sub mixerQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);

	if ($entity eq 'muting') {
		$request->addResult("_$entity", $client->prefGet("mute"));
	}
	elsif ($entity eq 'volume') {
		$request->addResult("_$entity", $client->prefGet("volume"));
	} else {
		$request->addResult("_$entity", $client->$entity());
	}
	
	$request->setStatusDone();
}


sub modeQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mode']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_mode', Slim::Player::Source::playmode($client));
	
	$request->setStatusDone();
}


sub musicfolderQuery {
	my $request = shift;
	
	$log->debug("musicfolderQuery()");

	# check this is the correct query.
	if ($request->isNotQuery([['musicfolder']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folderId = $request->getParam('folder_id');
	my $url      = $request->getParam('url');
	
	# url overrides any folderId
	my $params = ();
	
	if (defined $url) {
		$params->{'url'} = $url;
	} else {
		# findAndScanDirectory sorts it out if $folderId is undef
		$params->{'id'} = $folderId;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	# Pull the directory list, which will be used for looping.
	my ($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree($params);

	# create filtered data
	
	my $topPath = $topLevelObj->path;
	my $osName  = Slim::Utils::OSDetect::OS();
	my @data;

	for my $relPath (@$items) {

		$log->debug("relPath: $relPath" );
		
		my $url  = Slim::Utils::Misc::fixPath($relPath, $topPath) || next;

		$log->debug("url: $url" );

		# Amazingly, this just works. :)
		# Do the cheap compare for osName first - so non-windows users
		# won't take the penalty for the lookup.
		if ($osName eq 'win' && Slim::Music::Info::isWinShortcut($url)) {
			$url = Slim::Utils::Misc::fileURLFromWinShortcut($url);
		}
	
		my $item = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1,
		});
	
		if (!blessed($item) || !$item->can('content_type')) {

			next;
		}

		# Bug: 1360 - Don't show files referenced in a cuesheet
		next if ($item->content_type eq 'cur');

		push @data, $item;
	}

	$count = scalar(@data);

	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		
		my $cnt = 0;
		my $loopname = "folder_loop";
		
		for my $eachitem (@data[$start..$end]) {
			
			$request->addResultLoop($loopname, $cnt, 'id', $eachitem->id());
			$request->addResultLoop($loopname, $cnt, 'filename', Slim::Music::Info::fileName($eachitem->url()));
			
			if (Slim::Music::Info::isDir($eachitem)) {
				$request->addResultLoop($loopname, $cnt, 'type', 'folder');
			} elsif (Slim::Music::Info::isPlaylist($eachitem)) {
				$request->addResultLoop($loopname, $cnt, 'type', 'playlist');
			} elsif (Slim::Music::Info::isSong($eachitem)) {
				$request->addResultLoop($loopname, $cnt, 'type', 'track');
			} elsif (Slim::Music::Info::isSong($eachitem)) {
				$request->addResultLoop($loopname, $cnt, 'type', 'unknown');
			}
			
			$cnt++;
		}
	}

	# we might have changed - flush to the db to be in sync.
	$topLevelObj->update;
	
	$request->setStatusDone();
}


sub playerXQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['player'], ['count', 'name', 'address', 'ip', 'id', 'model', 'displaytype']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity      = $request->getRequest(1);
	my $clientparam = $request->getParam('_IDorIndex');
	
	if ($entity eq 'count') {
		$request->addResult("_$entity", Slim::Player::Client::clientCount());

	} else {	
		my $client;
		
		# were we passed an ID?
		if (defined $clientparam && Slim::Player::Client::getClient($clientparam)) {

			$client = Slim::Player::Client::getClient($clientparam);

		} else {
		
			# otherwise, try for an index
			my @clients = Slim::Player::Client::clients();

			if (defined $clientparam && defined $clients[$clientparam]) {
				$client = $clients[$clientparam];
			}
		}
		
		if (defined $client) {

			if ($entity eq "name") {
				$request->addResult("_$entity", $client->name());
			} elsif ($entity eq "address" || $entity eq "id") {
				$request->addResult("_$entity", $client->id());
			} elsif ($entity eq "ip") {
				$request->addResult("_$entity", $client->ipport());
			} elsif ($entity eq "model") {
				$request->addResult("_$entity", $client->model());
			} elsif ($entity eq "displaytype") {
				$request->addResult("_$entity", $client->vfdmodel());
			}
		}
	}
	
	$request->setStatusDone();
}


sub playersQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['players']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my @prefs;
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		@prefs = split(/,/, $pref_list);
	}
	
	
	my $count = Slim::Player::Client::clientCount();
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerindex', $idx);
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));

				for my $pref (@prefs) {
					if (defined(my $value = $eachclient->prefGet($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$idx++;
				$cnt++;
			}	
		}
	}
	
	$request->setStatusDone();
}


sub playlistPlaylistsinfoQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['playlistsinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $playlistObj = $client->currentPlaylist();
	
	if (blessed($playlistObj)) {
		if ($playlistObj->can('id')) {
			$request->addResult("id", $playlistObj->id());
		}

		$request->addResult("name", $playlistObj->title());
				
		$request->addResult("modified", $client->currentPlaylistModified());

		$request->addResult("url", $playlistObj->url());
	}
	
	$request->setStatusDone();
}


sub playlistXQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['name', 'url', 'modified', 
			'tracks', 'duration', 'artist', 'album', 'title', 'genre', 'path', 
			'repeat', 'shuffle', 'index', 'jump', 'remote']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);
	my $index  = $request->getParam('_index');
		
	if ($entity eq 'repeat') {
		$request->addResult("_$entity", Slim::Player::Playlist::repeat($client));

	} elsif ($entity eq 'shuffle') {
		$request->addResult("_$entity", Slim::Player::Playlist::shuffle($client));

	} elsif ($entity eq 'index' || $entity eq 'jump') {
		$request->addResult("_$entity", Slim::Player::Source::playingSongIndex($client));

	} elsif ($entity eq 'name' && defined(my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("_$entity", Slim::Music::Info::standardTitle($client, $playlistObj));

	} elsif ($entity eq 'url') {
		my $result = $client->currentPlaylist();
		$request->addResult("_$entity", $result);

	} elsif ($entity eq 'modified') {
		$request->addResult("_$entity", $client->currentPlaylistModified());

	} elsif ($entity eq 'tracks') {
		$request->addResult("_$entity", Slim::Player::Playlist::count($client));

	} elsif ($entity eq 'path') {
		my $result = Slim::Player::Playlist::url($client, $index);
		$request->addResult("_$entity",  $result || 0);

	} elsif ($entity eq 'remote') {
		if (defined (my $url = Slim::Player::Playlist::url($client, $index))) {
			$request->addResult("_$entity", Slim::Music::Info::isRemoteURL($url));
		}
		
	} elsif ($entity =~ /(duration|artist|album|title|genre)/) {

		my $track = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => Slim::Player::Playlist::song($client, $index),
			'create'   => 1,
			'readTags' => 1,
		});

		if (blessed($track) && $track->can('secs')) {

			# Just call the method on Track
			if ($entity eq 'duration') {

				$request->addResult("_$entity", $track->secs());
			
			} elsif ($entity eq 'album' || $entity eq 'artist' || $entity eq 'genre') {

				$request->addResult("_$entity", $track->$entity->name || 0);

			} else {

				$request->addResult("_$entity", $track->$entity());
			}
		}
	}
	
	$request->setStatusDone();
}


sub playlistsTracksQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	# "playlisttracks" is deprecated (July 06).
	if ($request->isNotQuery([['playlisttracks']]) &&
		$request->isNotQuery([['playlists'], ['tracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tags       = 'gald';
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $tagsprm    = $request->getParam('tags');
	my $playlistID = $request->getParam('playlist_id');

	if (!defined $playlistID) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	my $iterator;
	my @tracks;

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	my $playlistObj = Slim::Schema->find('Playlist', $playlistID);

	if (blessed($playlistObj) && $playlistObj->can('tracks')) {
		$iterator = $playlistObj->tracks();
	}

	if (defined $iterator) {

		my $count = $iterator->count();

		$request->addResult("count", $count);
		
		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		my $cur = $start;
		my $cnt = 0;

		if ($valid) {

			for my $eachitem ($iterator->slice($start, $end)) {

				_addSong($request, 'playlisttracks_loop', $cnt, $eachitem, $tags, 
						"playlist index", $cur);

				$cur++;
				$cnt++;
			}
		}

	} else {

		$request->addResult("count", 0);
	}

	$request->setStatusDone();	
}


sub playlistsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search	 = $request->getParam('search');
	my $tags     = $request->getParam('tags') || '';

	# Normalize any search parameters
	if (defined $search) {
		$search = Slim::Utils::Text::searchStringSplit($search);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	my $rs = Slim::Schema->rs('Playlist')->getPlaylists('all', $search);

	if (defined $rs) {

		my $numitems = $rs->count;
		
		$request->addResult("count", $numitems);
		
		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $numitems);

		if ($valid) {
			my $cnt = 0;

			for my $eachitem ($rs->slice($start, $end)) {

				$request->addResultLoop('playlists_loop', $cnt, "id", $eachitem->id);
				$request->addResultLoop('playlists_loop', $cnt, "playlist", $eachitem->title);
				$request->addResultLoop('playlists_loop', $cnt, "url", $eachitem->url) if ($tags =~ /u/);

				$cnt++;
			}
		}
	} 
	
	$request->setStatusDone();
}


sub playerprefQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client   = $request->client();
	my $prefName = $request->getParam('_prefname');
	
	if (!defined $prefName) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', $client->prefGet($prefName));
	
	$request->setStatusDone();
}


sub powerQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_power', $client->power());
	
	$request->setStatusDone();
}


sub prefQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['pref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $prefName = $request->getParam('_prefname');
	
	if (!defined $prefName) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', $prefs->get($prefName));
	
	$request->setStatusDone();
}


sub rateQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rate']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_rate', Slim::Player::Source::rate($client));
	
	$request->setStatusDone();
}


sub rescanQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescan query

	$request->addResult('_rescan', Slim::Music::Import->stillScanning() ? 1 : 0);
	
	$request->setStatusDone();
}


sub rescanprogressQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescanprogress']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescanprogress query

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);

		# get progress from DB
		my $args = {
			'type' => 'importer',
		};

		my @progress = Slim::Schema->rs('Progress')->search( $args, { 'order_by' => 'start,id' } )->all;

		# calculate total elapsed time
		my $total_time = 0;
		for my $p (@progress) {
			my $runtime = ($p->finish || time()) - $p->start;
			$total_time += $runtime;
		}

		# report it
		my $hrs  = int($total_time / 3600);
		my $mins = int(($total_time - $hrs * 60)/60);
		my $sec  = $total_time - 3600 * $hrs - 60 * $mins;
		$request->addResult('totaltime', sprintf("%02d:%02d:%02d", $hrs, $mins, $sec));

		# now indicate % completion for all importers
		for my $p (@progress) {

			my $percComplete = $p->finish ? 100 : $p->total ? $p->done / $p->total * 100 : -1;
			$request->addResult($p->name(), int($percComplete));
		}
	
	# if we're not scanning, just say so...
	} else {
		$request->addResult('rescan', 0);
	}

	$request->setStatusDone();
}


sub searchQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['search']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $query    = $request->getParam('term');

	if (!defined $query || $query eq '') {
		$request->setStatusBadParams();
		return;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);
	}

	my $totalCount = 0;
        my $search     = Slim::Utils::Text::searchStringSplit($query);
	my %results    = ();
	my @types      = Slim::Schema->searchTypes;

	# Ugh - we need two loops here, as "count" needs to come first.
	for my $type (@types) {

		my $rs      = Slim::Schema->rs($type)->searchNames($search);
		my $count   = $rs->count || 0;

		$results{$type}->{'rs'}    = $rs;
		$results{$type}->{'count'} = $count;

		$totalCount += $count;
	}

	$request->addResult('count', $totalCount);

	for my $type (@types) {

		my $count = $results{$type}->{'count'};

		$request->addResult("${type}s_count", $count);

		my $loopName  = "${type}s_loop";
		my $loopCount = 0;

		for my $result ($results{$type}->{'rs'}->slice(0, $quantity)) {

			# add result to loop
			$request->addResultLoop($loopName, $loopCount, "${type}_id", $result->id);
			$request->addResultLoop($loopName, $loopCount, $type, $result->name);

			$loopCount++;
		}
	}
	
	$request->setStatusDone();
}


sub serverstatusQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['serverstatus']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
 	if (Slim::Music::Import->stillScanning()) {
 		$request->addResult('rescan', "1");
 	}
 	
 	# add version
 	$request->addResult('version', $::VERSION);

	# add totals
	$request->addResult("info total albums", Slim::Schema->count('Album'));
	$request->addResult("info total artists", Slim::Schema->rs('Contributor')->browse->count);
	$request->addResult("info total genres", Slim::Schema->count('Genre'));
	$request->addResult("info total songs", Slim::Schema->rs('Track')->browse->count);

	my %savePrefs;
	if (defined(my $pref_list = $request->getParam('prefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'server'} = \@prefs;
	
		for my $pref (@{$savePrefs{'server'}}) {
			if (defined(my $value = $prefs->get($pref))) {
				$request->addResult($pref, $value);
			}
		}
	}
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'player'} = \@prefs;
		
	}


	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my $count = Slim::Player::Client::clientCount();
	$request->addResult('player count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));
				for my $pref (@{$savePrefs{'player'}}) {
					if (defined(my $value = $eachclient->prefGet($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$cnt++;
			}	
		}
	}
	
	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# the filter function decides, based on a notified request, if the serverstatus
		# query must be re-executed.
		sub serverstatusFilter{
			my $self = shift;
			my $request = shift;
			
			# we want to know about rescan and all client notifs
			if ($request->isCommand([['rescan', 'client']])) {
				return 1;
			}
			
			# we want to know about any pref in our array
			if (defined(my $prefsPtr = $self->privateData()->{'server'})) {
				if ($request->isCommand([['pref']])) {
					if (defined(my $reqpref = $request->getParam('_prefname'))) {
						return grep($reqpref, @{$prefsPtr});
					}
				}
			}
			if (defined(my $prefsPtr = $self->privateData()->{'player'})) {
				if ($request->isCommand([['playerpref']])) {
					if (defined(my $reqpref = $request->getParam('_prefname'))) {
						return grep($reqpref, @{$prefsPtr});
					}
				}
			}
			return 0;
		}
	
		# store the prefs array as private data so our filter above can find it back
		$request->privateData(\%savePrefs);
		
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&serverstatusFilter);
	}
	
	$request->setStatusDone();
}


sub signalstrengthQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['signalstrength']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_signalstrength', $client->signalStrength() || 0);
	
	$request->setStatusDone();
}


sub sleepQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $isValue = $client->sleepTime() - Time::HiRes::time();
	if ($isValue < 0) {
		$isValue = 0;
	}
	
	$request->addResult('_sleep', $isValue);
	
	$request->setStatusDone();
}


sub statusQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['status']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}
	
	# get the initial parameters
	my $client = $request->client();
	
	# accomodate the fact we can be called automatically when the client is gone
	if (!defined($client)) {
		$request->addResult('error', "invalid player");
		$request->registerAutoExecute('-');
		$request->setStatusDone();
		return;
	}
		
	my $SP3  = ($client->model() eq 'slimp3');
	my $SQ   = ($client->model() eq 'softsqueeze');
	my $SB   = ($client->model() eq 'squeezebox');
	my $SB2  = ($client->model() eq 'squeezebox2');
	my $TS   = ($client->model() eq 'transporter');
	my $RSC  = ($client->model() eq 'http');
	
	my $connected = $client->connected() || 0;
	my $power     = $client->power();
	my $repeat    = Slim::Player::Playlist::repeat($client);
	my $shuffle   = Slim::Player::Playlist::shuffle($client);
	my $songCount = Slim::Player::Playlist::count($client);
	my $idx = 0;
		
	# add player info...
	$request->addResult("player_name", $client->name());
	$request->addResult("player_connected", $connected);
	
	if (!$RSC) {
		$request->addResult("power", $power);
	}
	
	if ($SB || $SB2 || $TS) {
		$request->addResult("signalstrength", ($client->signalStrength() || 0));
	}
	
	# this will be true for http class players
	if ($power) {
	
		$request->addResult('mode', Slim::Player::Source::playmode($client));

		if (my $song = Slim::Player::Playlist::url($client)) {

			if (Slim::Music::Info::isRemoteURL($song)) {
				$request->addResult('remote', 1);
				$request->addResult('current_title', 
					Slim::Music::Info::getCurrentTitle($client, $song));
			}
			
			$request->addResult('time', 
				Slim::Player::Source::songTime($client));
			$request->addResult('rate', 
				Slim::Player::Source::rate($client));
			
			my $track = Slim::Schema->rs('Track')->objectForUrl($song);

			my $dur   = 0;

			if (blessed($track) && $track->can('secs')) {

				$dur = $track->secs;
			}

			if ($dur) {
				$request->addResult('duration', $dur);
			}
		}
		
		if ($client->currentSleepTime()) {

			my $sleep = $client->sleepTime() - Time::HiRes::time();
			$request->addResult('sleep', $client->currentSleepTime() * 60);
			$request->addResult('will_sleep_in', ($sleep < 0 ? 0 : $sleep));
		}
		
		if (Slim::Player::Sync::isSynced($client)) {

			my $master = Slim::Player::Sync::masterOrSelf($client);

			$request->addResult('sync_master', $master->id());

			my @slaves = Slim::Player::Sync::slaves($master);
			my @sync_slaves = map { $_->id } @slaves;

			$request->addResult('sync_slaves', join(",", @sync_slaves));
		}
	
		if (!$RSC) {
			# undefined for remote streams
			$request->addResult("mixer volume", $client->prefGet("volume"));
		}
		
		if ($SB || $SP3) {
			$request->addResult("mixer treble", $client->treble());
			$request->addResult("mixer bass", $client->bass());
		}

		if ($SB) {
			$request->addResult("mixer pitch", $client->pitch());
		}

		$request->addResult("playlist repeat", $repeat); 
		$request->addResult("playlist shuffle", $shuffle); 
	
		if (defined (my $playlistObj = $client->currentPlaylist())) {
			$request->addResult("playlist_id", $playlistObj->id());
			$request->addResult("playlist_name", $playlistObj->title());
			$request->addResult("playlist_modified", $client->currentPlaylistModified());
		}

		if ($songCount > 0) {
			$idx = Slim::Player::Source::playingSongIndex($client);
			$request->addResult("playlist_cur_index", $idx);
			$request->addResult("playlist_timestamp", $client->currentPlaylistUpdateTime())
		}

		$request->addResult("playlist_tracks", $songCount);
	}
	
	if ($songCount > 0 && $power) {
	
		# get the other parameters
		my $tags     = $request->getParam('tags');
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');
	
		$tags = 'gald' if !defined $tags;
		my $loop = 'playlist_loop';

		# we can return playlist data.
		# which mode are we in?
		my $modecurrent = 0;

		if (defined($index) && ($index eq "-")) {
			$modecurrent = 1;
		}
		
		# if repeat is 1 (song) and modecurrent, then show the current song
		if ($modecurrent && ($repeat == 1) && $quantity) {

			_addSong($request, $loop, 0, 
				Slim::Player::Playlist::song($client, $idx), $tags,
				'playlist index', $idx
			);

		} else {

			my ($valid, $start, $end);
			
			if ($modecurrent) {
				($valid, $start, $end) = $request->normalize($idx, scalar($quantity), $songCount);
			} else {
				($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $songCount);
			}

			if ($valid) {
				my $count = 0;

				for ($idx = $start; $idx <= $end; $idx++){
					_addSong(	$request, $loop, $count, 
								Slim::Player::Playlist::song($client, $idx), $tags,
								'playlist index', $idx
							);
					$count++;
					::idleStreams() ;
				}
				
				my $repShuffle = $prefs->get('reshuffleOnRepeat');
				my $canPredictFuture = ($repeat == 2)  			# we're repeating all
										&& 						# and
										(	($shuffle == 0)		# either we're not shuffling
											||					# or
											(!$repShuffle));	# we don't reshuffle
				
				if ($modecurrent && $canPredictFuture && ($count < scalar($quantity))) {

					# wrap around the playlist...
					($valid, $start, $end) = $request->normalize(0, (scalar($quantity) - $count), $songCount);		

					if ($valid) {

						for ($idx = $start; $idx <= $end; $idx++){

							_addSong($request, $loop, $count, 
								Slim::Player::Playlist::song($client, $idx), $tags,
								'playlist index', $idx
							);

							$count++;
							::idleStreams() ;
						}
					}
				}
			}
		}
	}


	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# the filter function decides, based on a notified request, if the status
		# query must be re-executed.
		sub statusFilter{
			my $self = shift;
			my $request = shift;
			
			# retrieve the clientid, abort if not about us
			my $clientid = $request->clientid();
			return 0 if !defined $clientid;
			return 0 if $clientid ne $self->clientid();
			
			# commands we ignore
			return 0 if $request->isCommand([['ir', 'button', 'debug', 'pref', 'playerpref', 'display']]);
			return 0 if $request->isCommand([['playlist'], ['open', 'jump']]);

			# special case: the client is gone!
			if ($request->isCommand([['client'], ['forget']])) {
				
				# pretend we do not need a client, otherwise execute() fails
				# and validate() deletes the client info!
				$self->needClient(0);
				
				# we'll unsubscribe above if there is no client
				return 1;
			}


			# don't delay for newsong
			if ($request->isCommand([['playlist'], ['newsong']])) {

				return 1;
			}

			# send everyother notif with a small delay to accomodate
			# bursts of commands
			return 1;
		}
		
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&statusFilter);
	}
	
	$request->setStatusDone();
}


sub songinfoQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['songinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags  = 'abcdefghijklmnopqrstvwxyz'; # all letter EXCEPT u
	my $track;

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $url	     = $request->getParam('url');
	my $trackID  = $request->getParam('track_id');
	my $tagsprm  = $request->getParam('tags');

	if (!defined $trackID && !defined $url) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	# find the track
	if (defined $trackID){

		if ($tags !~ /u/) {
			$tags .= 'u';
		}

		$track = Slim::Schema->find('Track', $trackID);

	} else {

		if (defined $url && Slim::Music::Info::isSong($url)){

			$track = Slim::Schema->rs('Track')->objectForUrl($url)
		}
	}
	
	if (blessed($track) && $track->can('id')) {

		my $hashRef = _songData($track, $tags);
		my $count = scalar (keys %{$hashRef});

		$request->addResult("count", $count);

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid) {
			my $idx = 0;

			while (my ($key, $val) = each %{$hashRef}) {

				if ($idx >= $start && $idx <= $end) {
					$request->addResult($key, $val);
				}

				$idx++;
 			}
		}
	}

	$request->setStatusDone();
}


sub syncQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	if (Slim::Player::Sync::isSynced($client)) {
	
		my @buddies = Slim::Player::Sync::syncedWith($client);
		my @sync_buddies = map { $_->id() } @buddies;

		$request->addResult('_sync', join(",", @sync_buddies));
	} else {
	
		$request->addResult('_sync', '-');
	}
	
	$request->setStatusDone();
}


sub timeQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_time', Slim::Player::Source::songTime($client));
	
	$request->setStatusDone();
}

sub titlesQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['titles', 'tracks', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $where  = {};
	my $attr   = {};

	my $tags   = 'gald';

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tagsprm       = $request->getParam('tags');
	my $sort          = $request->getParam('sort');
	my $search        = $request->getParam('search');
	my $genreID       = $request->getParam('genre_id');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $year          = $request->getParam('year');

	if ($request->paramNotOneOfIfDefined($sort, ['title', 'tracknum'])) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	# note that this is not equivalent to 
	# $val = $param || $default;
	# since when $default eq '' -> $val eq $param
	$tags = $tagsprm if defined $tagsprm;

	# Normalize any search parameters
	if (specified($search)) {
		$where->{'me.titlesearch'} = {'like' => Slim::Utils::Text::searchStringSplit($search)};
	}

	if (defined $albumID){
		$where->{'me.album'} = $albumID;
	}

	if (defined $year) {
		$where->{'me.year'} = $year;
	}

	# we don't want client playlists (Now playing), transporter sources,
	# or playlists.
	$where->{'me.content_type'} = {'!=', ['cpl', 'src', 'ssp']};

	# Manage joins
	if (defined $genreID) {

		$where->{'genreTracks.genre'} = $genreID;

		push @{$attr->{'join'}}, 'genreTracks';
#		$attr->{'distinct'} = 1;
	}

	if (defined $contributorID) {
	
		# handle the case where we're asked for the VA id => return compilations
		if ($contributorID == Slim::Schema->variousArtistsObject->id) {
			$where->{'album.compilation'} = 1;
			push @{$attr->{'join'}}, 'album';
		}
		else {	
			$where->{'contributorTracks.contributor'} = $contributorID;
			push @{$attr->{'join'}}, 'contributorTracks';
		}
	}

	if ($sort && $sort eq "tracknum") {

		if (!($tags =~ /t/)) {
			$tags = $tags . "t";
		}

		$attr->{'order_by'} =  "me.disc, me.tracknum, concat('0', me.titlesort)";
	}
	else {
		$attr->{'order_by'} =  "me.titlesort";
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult("rescan", 1);
	}

	my $rs = Slim::Schema->rs('Track')->search($where, $attr)->distinct;

	my $count = $rs->count;

	$request->addResult("count", $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $cnt = 0;

		for my $item ($rs->slice($start, $end)) {

			_addSong($request, 'titles_loop', $cnt++, $item, $tags);

			::idleStreams();
		}
	}

	$request->setStatusDone();
}


sub versionQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the version query

	$request->addResult('_version', $::VERSION);
	
	$request->setStatusDone();
}


sub yearsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['years']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');	
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	my $rs = Slim::Schema->resultset('Year')->browse->search($where, $attr);

	my $count = $rs->count;

	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'years_loop';
		my $cnt = 0;

		for my $eachitem ($rs->slice($start, $end)) {
			$request->addResultLoop($loopname, $cnt, 'year', $eachitem->id);
			$cnt++;
		}
	}

	$request->setStatusDone();
}

################################################################################
# Special queries
################################################################################

=head2 dynamicAutoQuery( $request, $query, $funcptr, $data )

 This function is a helper function for any query that needs to poll enabled
 plugins. In particular, this is used to implement the CLI radios query,
 that returns all enabled radios plugins. This function is best understood
 by looking as well in the code used in the plugins.
 
 Each plugins does in initPlugin (edited for clarity):
 
    $funcptr = addDispatch(['radios'], [0, 1, 1, \&cli_radiosQuery]);
 
 For the first plugin, $funcptr will be undef. For all the subsequent ones
 $funcptr will point to the preceding plugin cli_radiosQuery() function.
 
 The cli_radiosQuery function looks like:
 
    sub cli_radiosQuery {
      my $request = shift;
      
      my $data = {
         #...
      };
 
      dynamicAutoQuery($request, 'radios', $funcptr, $data);
    }
 
 The plugin only defines a hash with its own data and calls dynamicAutoQuery.
 
 dynamicAutoQuery will call each plugin function recursively and add the
 data to the request results. It checks $funcptr for undefined to know if
 more plugins are to be called or not.
 
=cut

sub dynamicAutoQuery {
	my $request = shift;                       # the request we're handling
	my $query   = shift || return;             # query name
	my $funcptr = shift;                       # data returned by addDispatch
	my $data    = shift || return;             # data to add to results
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([[$query]])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity') || 0;
	my $sort     = $request->getParam('sort');

	# we have multiple times the same resultset, so we need a loop, named
	# after the query name (this is never printed, it's just used to distinguish
	# loops in the same request results.
	my $loop = $query . 's_loop';

	# if the caller asked for results in the query ("radios 0 0" returns 
	# immediately)
	if ($quantity) {

		# add the data to the results
		my $cnt = $request->getResultLoopCount($loop) || 0;
		$request->setResultLoopHash($loop, $cnt, $data);
		
		# more to jump to?
		# note we carefully check $funcptr is not a lemon
		if (defined $funcptr && ref($funcptr) eq 'CODE') {
			
			eval { &{$funcptr}($request) };
	
			# arrange for some useful logging if we fail
			if ($@) {

				logError("While trying to run function coderef: [$@]");
				$request->setStatusBadDispatch();
				$request->dump('Request');
			}
		}
		
		# $funcptr is undefined, we have everybody, now slice & count
		else {
			
			# sort if requested to do so
			if ($sort) {
				$request->sortResultLoop($loop, $sort);
			}
			
			# slice as needed
			my $count = $request->getResultLoopCount($loop);
			$request->sliceResultLoop($loop, $index, $quantity);
			$request->setResultFirst('count', $count);
			
			# don't forget to call that to trigger notifications, if any
			$request->setStatusDone();
		}
	}
	else {
		$request->setStatusDone();
	}
}

################################################################################
# Helper functions
################################################################################

sub _addSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $index     = shift; # loop index
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $prefixKey = shift; # prefix key, if any
	my $prefixVal = shift; # prefix value, if any   

	# get the hash with the data	
	my $hashRef = _songData($pathOrObj, $tags);
	
	# add the prefix in the first position, use a fancy feature of
	# Tie::LLHash
	if (defined $prefixKey) {
#		(tied %{$hashRef})->first($prefixKey => $prefixVal);
		(tied %{$hashRef})->Unshift($prefixKey => $prefixVal);
	}
	
	# add it directly to the result loop
	$request->setResultLoopHash($loop, $index, $hashRef);
}


sub _songData {
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use

	my $track     = Slim::Schema->rs('Track')->objectForUrl($pathOrObj);

	if (!blessed($track) || !$track->can('id')) {

		logError("Called with invalid object or path: $pathOrObj!");
		
		# For some reason, $pathOrObj may be an id... try that before giving up...
		if ($pathOrObj =~ /^\d+$/) {
			$track = Slim::Schema->find('Track', $pathOrObj);
		}

		if (!blessed($track) || !$track->can('id')) {

			logError("Can't make track from: $pathOrObj!");
			return;
		}
	}
	
	# define an ordered hash for our results
#	tie (my %returnHash, "Tie::LLHash", {lazy => 1});
	tie (my %returnHash, "Tie::IxHash");

	# add fields present no matter $tags
	$returnHash{'id'}    = $track->id;
	$returnHash{'title'} = $track->title;

	my %tagMap = (
		# Tag    Tag name             Track method         Track field
		#-------------------------------------------------------------
		# '.' => ['id',               'id'],               #id
		  'u' => ['url',              'url'],              #url
		  'o' => ['type',             'content_type'],     #content_type
		# '.' => ['title',            'title'],            #title
		#                                                  #titlesort 
		#                                                  #titlesearch 
		  'e' => ['album_id',         'albumid'],          #album 
		  't' => ['tracknum',         'tracknum'],         #tracknum
		  'n' => ['modificationTime', 'modificationTime'], #timestamp
		  'f' => ['filesize',         'filesize'],         #filesize
		#                                                  #tag 
		  'i' => ['disc',             'disc'],             #disc
		  'j' => ['coverart',         'coverArtExists'],   #cover
		  'x' => ['remote',           'remote'],           #remote 
		#                                                  #audio 
		#                                                  #audio_size 
		#                                                  #audio_offset
		  'y' => ['year',             'year'],             #year
		  'd' => ['duration',         'secs'],             #secs
		#                                                  #vbr_scale 
		  'r' => ['bitrate',          'prettyBitRate'],    #bitrate
		#                                                  #samplerate 
		#                                                  #samplesize 
		#                                                  #channels 
		#                                                  #block_alignment
		#                                                  #endian 
		  'm' => ['bpm',              'bpm'],              #bpm
		  'v' => ['tagversion',       'tagversion'],       #tagversion
		  'z' => ['drm',              'drm'],              #drm
		#                                                  #musicmagic_mixable
		#                                                  #musicbrainz_id 
		#                                                  #playcount 
		#                                                  #lastplayed 
		#                                                  #lossless 
		  'w' => ['lyrics',           'lyrics'],           #lyrics 
		#                                                  #rating 
		#                                                  #replay_gain 
		#                                                  #replay_peak

		# Tag    Tag name             Relationship   Method         Track relationship
		#--------------------------------------------------------------------
		  'a' => ['artist',           'artist',      'name'],       #->contributors
		  'b' => ['band',             'band'],                      #->contributors
		  'c' => ['composer',         'composer'],                  #->contributors
		  'h' => ['conductor',        'conductor'],                 #->contributors
		  's' => ['artist_id',        'artist',      'id'],         #->contributors

		  'l' => ['album',            'album',       'title'],      #->album.title
		  'q' => ['disccount',        'album',       'discc'],      #->album.discc
		  'J' => ["artwork_track_id", 'album',       'artwork'],    #->album.artwork

		  'g' => ['genre',            'genre',       'name'],       #->genre_track->genre.name
		  'p' => ['genre_id',         'genre',       'id'],         #->genre_track->genre.id

		  'k' => ['comment',          'comment'],                   #->comment_object

		# Tag    Tag name             Track method         Track relationship
		#--------------------------------------------------------------------

	);

	# loop so that stuff is returned in the order given...
	for my $tag (split //, $tags) {

		# if we have a method for the tag
		if (defined(my $method = $tagMap{$tag}->[1])) {
			
			if ($method ne '') {

				my $value;

				if (defined(my $submethod = $tagMap{$tag}->[2])) {
					if (defined(my $related = $track->$method)) {
						$value = $related->$submethod();
					}
				}
				else {
					$value = $track->$method();
				}
				
				# if we have a value
				if (defined $value && $value ne '') {

					# add the tag to the result
					$returnHash{$tagMap{$tag}->[0]} = $value;
				}
			}
		}
	}

	return \%returnHash;
}

=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
