package ChatGPTSummary::Callback;

use strict;
use warnings;
use utf8;
use ChatGPTSummary::Utils;
use LWP::UserAgent;
use JSON qw/encode_json decode_json/;

use constant API_URI => 'https://api.openai.com/v1/chat/completions';

sub plugin {
    return MT->component('ChatGPTSummary');
}

sub hdlr_cms_post_save {
    my ( $eh, $app, $obj ) = @_;
    my $plugin = plugin();

    my $summary_generation = $obj->meta('field.summary_generation');
    if (defined $summary_generation) {
      if ( $summary_generation eq 'do_not_generate' ) {
          return;
      }
      elsif ( $summary_generation ne 'overwrite' && $obj->excerpt ) {
          return;
      }
    }
    elsif ( $obj->excerpt ) {
      return;
    }

    my $prompt_text = $plugin->get_config_value('prompt_text');
    my $post_text   = $obj->text;
    $post_text =~ s/<[^>]+>//xg;
    $prompt_text .= $post_text;
    $prompt_text =~ s/\n//xg;

    my $uri = URI->new(API_URI);
    my $req = HTTP::Request->new( POST => $uri );
    $req->header( 'Content-Type' => 'application/json' );
    $req->header( 'Authorization' => 'Bearer '
          . $plugin->get_config_value('api_key') );
    $req->header(
        'OpenAI-Organization' => $plugin->get_config_value('api_org') );
    $req->content(
        encode_json(
            {
                model    => "gpt-3.5-turbo",
                messages => [
                    {
                        role    => "user",
                        content => $prompt_text,
                    }
                ]
            }
        )
    );
    my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );
    $ua->timeout( $plugin->get_config_value('timeout_seconds') );

    my $res;
    eval { $res = $ua->request($req) };
    if ($@) {
        MT->log({
            level => MT::Log::ERROR(),
            message => "API ERROR: $@",
        });
        return;
    }
    elsif (!$res->is_success) {
        die "API ERROR: " . $res->status_line;
    }

    my $res_text = $res->{'_content'};
    my $decoded_res = decode_json($res_text);
    if ($decoded_res->{choices} && @{$decoded_res->{choices}} > 0) {
        my $summary = $decoded_res->{choices}[0]{message}{content};
        if ($summary) {
            my $entry = MT->model('entry')->load($obj->id);
            $entry->excerpt($summary);
            if ($entry->save) {
                MT->log({
                    level => MT::Log::INFO(),
                    message => "Summary updated for entry ID: " . $entry->id . ", title: " . $entry->title,
                });
            } else {
                MT->log({
                    level => MT::Log::ERROR(),
                    message => "Failed to save summary for entry ID: " . $entry->id . ", title: " . $entry->title . ": " . $entry->errstr,
                });
            }
        } else {
            MT->log({
                level => MT::Log::ERROR(),
                message => "API ERROR: Summary content not found for entry ID: " . $obj->id,
            });
        }
    } else {
        MT->log({
            level => MT::Log::ERROR(),
            message => "API ERROR: Invalid response structure for entry ID: " . $obj->id,
        });
    }

    # カスタムフィールドの値が 'overwrite' の場合 'generate_if_empty' に更新
    if ( $summary_generation eq 'overwrite' ) {
        $obj->meta('field.summary_generation', 'generate_if_empty');
        unless ($obj->save) {
            MT->log({
                level   => MT::Log::ERROR(),
                message => "Failed to save entry " . $obj->id . ": " . $obj->errstr,
            });
        }
    }

}

1;
