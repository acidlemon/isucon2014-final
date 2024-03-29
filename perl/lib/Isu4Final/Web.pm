package Isu4Final::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use Redis::Fast;
use JSON::XS;
use File::Copy;
use File::Path;
use File::Basename qw/dirname/;

my $self_ip;
sub self_ip {
    if (!$self_ip) {
        ($self_ip) = `ifconfig eth1 | grep "inet addr"` =~ /addr:(\S+)/;
    }

    return $self_ip;
}

sub advertiser_id {
    my ( $self, $c ) = @_;
    return $c->req->header('X-Advertiser-Id');
}

my $redis;
sub redis {
    $redis ||= Redis::Fast->new(
        server => 'srv1:6379'
    );
    return $redis;
}

my $json;
sub json {
    $json ||= JSON::XS->new;
    return $json;
}

sub ad_key {
    my ( $self, $slot, $id ) = @_;
    return "isu4:ad:${slot}-${id}";
}

sub asset_key {
    my ( $self, $slot, $id ) = @_;
    return "isu4:asset:${slot}-${id}";
}

sub asset_path {
    my ($self, $slot, $id) = @_;

    return "/var/tmp/isu4videos/slots/${slot}/ads/${id}/asset";
}

sub advertiser_key {
    my ( $self, $id ) = @_;
    return "isu4:advertiser:$id";
}

sub slot_key {
    my ( $self, $slot ) = @_;
    return "isu4:slot:$slot";
}

sub log_key {
    my ($self, $id) = @_;
    return "isu4:log:$id";
}

sub next_ad_id {
    my $self = shift;
    $self->redis->incr('isu4:ad-next');
}

sub next_ad {
    my ( $self, $c ) = @_;
    my $slot = $c->args->{slot};
    my $key = $self->slot_key($slot);

    my $id  = $self->redis->rpoplpush($key, $key);
    unless ( $id ) {
        return undef;
    }

    my $ad = $self->get_ad($c, $slot, $id);
    if ( $ad ) {
        return $ad;
    }
    else {
        $self->redis->lrem($key, 0, $id);
        $self->next_ad($c);
    }
}

sub get_ad {
    my ( $self, $c, $slot, $id ) = @_;
    my $key = $self->ad_key($slot, $id);
    my %ad  = $self->redis->hgetall($key);

    return undef if !%ad;

    $ad{impressions} = int($ad{impressions});
    $ad{asset}       = $c->req->address =~ /^10\./
        ? "http://".$ad{host}."/slots/${slot}/ads/${id}/asset"
        : $c->req->uri_for("/slots/${slot}/ads/${id}/asset")->as_string;
    $ad{counter}     = $c->req->uri_for("/slots/${slot}/ads/${id}/count")->as_string;
    $ad{redirect}    = $c->req->uri_for("/slots/${slot}/ads/${id}/redirect")->as_string;
    $ad{type}        = undef if $ad{type} eq '';
    return \%ad;
}


sub get_log {
    my ( $self, $id ) = @_;

    my $result = {};
    my @logs = $self->redis->lrange($self->log_key($id), 0, -1);

    for my $log (@logs) {
        my $data = $self->json->decode($log);
        my $ad_id = $data->{ad_id};
        $result->{ $ad_id } //= [];

        push @{ $result->{ $ad_id } }, $data;
    }

    return $result;
}

get '/' => sub {
    my ( $self, $c )  = @_;
    open my $in, $self->root_dir . '/public/index.html' or do {
        $c->halt(404);
    };
    $c->res->body(do { local $/; <$in> });
    close $in;
    return $c->res;
};

post '/slots/{slot:[^/]+}/ads' => sub {
    my ($self, $c) = @_;

    my $advertiser_id;
    unless ( $advertiser_id = $self->advertiser_id($c) ) {
        $c->halt(400);
    }

    my $slot  = $c->args->{slot};

    my $id  = $self->next_ad_id;
    my $key = $self->ad_key($slot, $id);

    $self->redis->hmset(
        $key,
        'slot'        => $slot,
        'id'          => $id,
        'title'       => $c->req->param('title'),
        'type'        => $c->req->param('type') || 'video/mp4',
        'advertiser'  => $advertiser_id,
        'destination' => $c->req->param('destination'),
        'impressions' => 0,
        'host'        => $self->self_ip,
    );

    my $asset_path = $self->asset_path($slot, $id);
    mkpath dirname($asset_path);
    move $c->req->header("X-FILE") || $c->req->uploads->{'asset'}->path, $asset_path or do {
        warn "move failed: ".$!;
        warn "X-FILE=".$c->req->header("X-FILE");
        $c->halt(500);
    };
    chmod 0644, $asset_path;

    $self->redis->rpush($self->slot_key($slot), $id);
    $self->redis->sadd($self->advertiser_key($advertiser_id), $key);

    $c->render_json($self->get_ad($c, $slot, $id));
};

get '/slots/{slot:[^/]+}/ad' => sub {
    my ($self, $c) = @_;

    my $ad = $self->next_ad($c);
    if ( $ad ) {
        $c->res->header('Content-Length' => 0);
        $c->redirect($c->req->uri_for('/slots/' . $c->args->{slot} . '/ads/' . $ad->{id})->as_string);
    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body($self->json->encode({ error => 'Not Found' }));
        return $c->res;
    }
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}' => sub {
    my ($self, $c) = @_;

    my $ad = $self->get_ad($c, $c->args->{slot}, $c->args->{id});
    if ( $ad ) {
        my $body = $self->json->encode($ad);
        $c->res->status(200);
        $c->res->header('Content-Length' => length($body));
        $c->res->content_type('application/json');
        $c->res->body($body);
    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body($self->json->encode({ error => 'Not Found' }));
    }
    return $c->res;
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/asset' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $ad = $self->get_ad($c, $slot, $id);

    if ( $ad ) {
        $c->res->content_type($ad->{type} || 'video/mp4');
        my $data = $self->redis->get($self->asset_key($slot, $id));


        my $range = $c->req->header('Range');
        if ( !$range ) {
            $c->res->header('Content-Length' => length($data));
            $c->res->body($data);
            return $c->res;
        }
        elsif ( $range =~ /\Abytes=(\d+)?-(\d+)?\z/ )  {
            my ( $head, $tail ) = ( $1, $2 );

            if ( !defined($head) && !defined($tail) ) {
                $c->halt(416);
            }
            my $length = length($data);

            $head ||= 0;
            $tail ||= $length - 1;

            if ( $head < 0 || $head >= $length || $tail < 0 ) {
                $c->halt(416);
            }

            my $partial_body = substr($data, $head, $tail - $head + 1);

            $c->res->status(206);
            $c->res->header('Content-Range' => "bytes ${head}-${tail}/${length}", 'Content-Length' => length($partial_body));

            $c->res->body($partial_body);
            return $c->res;

        }
        else {
            $c->halt(416);
        }

    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body($self->json->encode({ error => 'Not Found' }));
        return $c->res;
    }
};

post '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/count' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $key = $self->ad_key($slot, $id);

    unless ( $self->redis->exists($key) ) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body($self->json->encode({ error => 'Not Found' }));
        return $c->res;
    }

    $self->redis->hincrby($key, 'impressions', 1);

    $c->res->status(204);
    return $c->res;
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/redirect' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $ad = $self->get_ad($c, $slot, $id);

   unless ( $ad ) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body($self->json->encode({ error => 'Not Found' }));
        return $c->res;
    }

    my $user = $c->req->cookies->{isuad};
    my ($gender, $age) = split '/', $user;

    my $data = {
        ad_id  => $ad->{id},
        user   => $user,
        agent  => $c->req->env->{'HTTP_USER_AGENT'},
        age    => int($age),
        gender => ($gender eq '0' ? 'female' : $gender eq '1' ? 'male' : undef),
    };

    $self->redis->rpush($self->log_key($ad->{advertiser}), $self->json->encode($data));

    $c->redirect($ad->{destination});
};

get '/me/report' => sub {
    my ($self, $c) = @_;

    my $advertiser_id = $self->advertiser_id($c);

    unless ( $advertiser_id ) {
        $c->halt(401);
    }

    my $ad_keys = $self->redis->smembers( $self->advertiser_key($advertiser_id) );

    my $report = {};
    for my $ad_key ( @$ad_keys ) {
        my %ad = $self->redis->hgetall($ad_key);
        next unless %ad;
        $ad{impressions} = int($ad{impressions});
        $report->{$ad{id}} = { ad => \%ad, clicks => 0, impressions => $ad{'impressions'} };
    }

    my $logs = $self->get_log($advertiser_id);

    for my $ad_id ( keys %$logs ) {
        $report->{$ad_id}->{clicks} = scalar @{$logs->{$ad_id}};
    }

    $c->render_json($report);
};

get '/me/final_report' => sub {
    my ($self, $c) = @_;

    my $advertiser_id = $self->advertiser_id($c);

    unless ( $advertiser_id ) {
        $c->halt(401);
    }

    my $reports = {};
    my $ad_keys = $self->redis->smembers( $self->advertiser_key($advertiser_id) );
    for my $ad_key ( @$ad_keys ) {
        my %ad = $self->redis->hgetall($ad_key);
        next unless %ad;
        $ad{impressions} = int($ad{impressions});
        $reports->{$ad{id}} = { ad => \%ad, clicks => 0, impressions => int($ad{'impressions'}) };
    }

    my $logs = $self->get_log($advertiser_id);

    for my $ad_id ( keys %$reports ) {
        my $report = $reports->{$ad_id};
        my $log    = $logs->{$ad_id} || [];

        $report->{clicks} = scalar @$log;

        my $breakdown = {};

        $breakdown->{gender}      = {};
        $breakdown->{agents}      = {};
        $breakdown->{generations} = {};

        for my $row ( @$log ) {
            my $gender = $row->{gender} || 'unknown';
            $breakdown->{gender}->{$gender}++;

            my $agent = $row->{agent} || 'unknown';
            $breakdown->{agents}->{"$agent"}++;

            my $generation = 'unknown';
            if ( $row->{age} ) {
                $generation = int($row->{age} / 10 );
            }
            $breakdown->{generations}->{$generation}++;
        };


        $report->{breakdown} = $breakdown;
    }

    $c->render_json($reports);
};

post '/initialize' => sub {
    my ($self, $c) = @_;

    my @keys = $self->redis->keys('isu4:*');

    for my $key ( @keys ) {
        $self->redis->del($key);
    }

    $c->res->content_type('text/plain');
    $c->res->body('OK');
    return $c->res;
};

1;
