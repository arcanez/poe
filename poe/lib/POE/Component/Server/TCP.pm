# $Id$

package POE::Component::Server::TCP;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use Carp qw(carp croak);
use Socket qw(INADDR_ANY inet_ntoa inet_aton AF_INET AF_UNIX PF_UNIX);
use Errno qw(ECONNABORTED ECONNRESET);

# Explicit use to import the parameter constants.
use POE::Session;
use POE::Driver::SysRW;
use POE::Filter::Line;
use POE::Wheel::ReadWrite;
use POE::Wheel::SocketFactory;

sub DEBUG () { 0 }

# Create the server.  This is just a handy way to encapsulate
# POE::Session->create().  Because the states are so small, it uses
# real inline coderefs.

sub new {
  my $type = shift;

  # Helper so we don't have to type it all day.  $mi is a name I call
  # myself.
  my $mi = $type . '->new()';

  # If they give us lemons, tell them to make their own damn
  # lemonade.
  croak "$mi requires an even number of parameters" if (@_ & 1);
  my %param = @_;

  # Validate what we're given.
  croak "$mi needs a Port parameter" unless exists $param{Port};

  # Extract parameters.
  my $alias   = delete $param{Alias};
  my $address = delete $param{Address};
  my $hname   = delete $param{Hostname};
  my $port    = delete $param{Port};
  my $domain  = delete($param{Domain}) || AF_INET;
  my $concurrency = delete $param{Concurrency};

  foreach (
    qw(
      Acceptor Error ClientInput ClientConnected ClientDisconnected
      ClientError ClientFlushed
      ClientLow ClientHigh
    )
  ) {
    croak "$_ must be a coderef"
      if defined($param{$_}) and ref($param{$_}) ne 'CODE';
  }

  my $high_mark_level = delete $param{HighMark};
  my $low_mark_level  = delete $param{LowMark};
  my $high_event      = delete $param{ClientHigh};
  my $low_event       = delete $param{ClientLow};

  my $mark_param_count = (
    grep { defined $_ }
    ($high_mark_level, $low_mark_level, $high_event, $low_event)
  );
  if ($mark_param_count and $mark_param_count < 4) {
    croak "If you use the Mark settings, you must define all four";
  }

  $high_event = sub { } unless defined $high_event;
  $low_event  = sub { } unless defined $low_event;

  my $accept_callback = delete $param{Acceptor};
  my $error_callback  = delete $param{Error};

  my $client_input    = delete $param{ClientInput};

  # Acceptor and ClientInput are mutually exclusive.
  croak "$mi needs either an Acceptor or a ClientInput but not both"
    unless defined($accept_callback) xor defined($client_input);

  # Make sure ClientXyz are accompanied by ClientInput.
  unless (defined($client_input)) {
    foreach (grep /^Client/, keys %param) {
      croak "$_ not permitted without ClientInput";
    }
  }

  my $client_connected    = delete $param{ClientConnected};
  my $client_disconnected = delete $param{ClientDisconnected};
  my $client_error        = delete $param{ClientError};
  my $client_filter       = delete $param{ClientFilter};
  my $client_infilter     = delete $param{ClientInputFilter};
  my $client_outfilter    = delete $param{ClientOutputFilter};
  my $client_flushed      = delete $param{ClientFlushed};
  my $session_type        = delete $param{SessionType};
  my $session_params      = delete $param{SessionParams};
  my $server_started      = delete $param{Started};

  if (exists $param{Args}) {
    if (exists $param{ClientArgs}) {
      carp "Args is deprecated, and ignored since ClientArgs is present";
      delete $param{Args};
    }
    else {
      carp "Args is deprecated but allowed for now.  Please use ClientArgs";
    }
  }

  my $args                = delete($param{ClientArgs}) || delete($param{Args});

  # Defaults.

  $concurrency = -1 unless defined $concurrency;
  my $accept_session_id;

  if (!defined $address && defined $hname) {
    $address = inet_aton($hname);
  }
  $address = INADDR_ANY unless defined $address;

  $error_callback = \&_default_server_error unless defined $error_callback;
  $server_started = sub {} unless ref($server_started) eq 'CODE';

  $session_type = 'POE::Session' unless defined $session_type;
  if (defined($session_params) && ref($session_params)) {
    if (ref($session_params) ne 'ARRAY') {
      croak "SessionParams must be an array reference";
    }
  } else {
    $session_params = [ ];
  }

  if (defined $client_input) {
    $client_error  = \&_default_client_error unless defined $client_error;
    $client_connected    = sub {} unless defined $client_connected;
    $client_disconnected = sub {} unless defined $client_disconnected;
    $client_flushed      = sub {} unless defined $client_flushed;
    $args = [] unless defined $args;

    # Extra states.

    my $inline_states = delete $param{InlineStates};
    $inline_states = {} unless defined $inline_states;

    my $package_states = delete $param{PackageStates};
    $package_states = [] unless defined $package_states;

    my $object_states = delete $param{ObjectStates};
    $object_states = [] unless defined $object_states;

    my $shutdown_on_error = 1;
    if (exists $param{ClientShutdownOnError}) {
      $shutdown_on_error = delete $param{ClientShutdownOnError};
    }

    croak "InlineStates must be a hash reference"
      unless ref($inline_states) eq 'HASH';

    croak "PackageStates must be a list or array reference"
      unless ref($package_states) eq 'ARRAY';

    croak "ObjectsStates must be a list or array reference"
      unless ref($object_states) eq 'ARRAY';

    croak "ClientArgs must be an array reference"
      unless ref($args) eq 'ARRAY';

    # Revise the acceptor callback so it spawns a session.

    unless (defined $accept_callback) {
      $accept_callback = sub {
        my ($socket, $remote_addr, $remote_port) = @_[ARG0, ARG1, ARG2];


        $session_type->create(
          @$session_params,
          inline_states => {
            _start => sub {
              my ( $kernel, $session, $heap ) = @_[KERNEL, SESSION, HEAP];

              $heap->{shutdown} = 0;
              $heap->{shutdown_on_error} = $shutdown_on_error;

              # Unofficial UNIX support, suggested by Damir Dzeko.
              # Real UNIX socket support should go into a separate
              # module, but if that module only differs by four
              # lines of code it would be bad to maintain two
              # modules for the price of one.  One solution would be
              # to pull most of this into a base class and derive
              # TCP and UNIX versions from that.
              if (
                $domain == AF_UNIX or $domain == PF_UNIX
              ) {
                $heap->{remote_ip} = "LOCAL";
              }
              elsif (length($remote_addr) == 4) {
                $heap->{remote_ip} = inet_ntoa($remote_addr);
              }
              else {
                $heap->{remote_ip} =
                  Socket6::inet_ntop($domain, $remote_addr);
              }

              $heap->{remote_port} = $remote_port;

              $heap->{client} = POE::Wheel::ReadWrite->new(
                Handle       => splice(@_, ARG0, 1),
                Driver       => POE::Driver::SysRW->new(),
                _get_filters(
                  $client_filter,
                  $client_infilter,
                  $client_outfilter
                ),
                InputEvent   => 'tcp_server_got_input',
                ErrorEvent   => 'tcp_server_got_error',
                FlushedEvent => 'tcp_server_got_flush',

                (
                  $mark_param_count
                  ? (
                    HighMark  => $high_mark_level,
                    HighEvent => 'tcp_server_got_high',
                    LowMark   => $low_mark_level,
                    LowEvent  => 'tcp_server_got_low',
                  )
                  : ()
                ),
              );

              $client_connected->(@_);
            },
            tcp_server_got_high => $high_event,
            tcp_server_got_low => $low_event,

            # To quiet ASSERT_STATES.
            _child  => sub { },

            tcp_server_got_input => sub {
              return if $_[HEAP]->{shutdown};
              $client_input->(@_);
              undef;
            },
            tcp_server_got_error => sub {
              DEBUG and warn(
                "$$: $alias child Error ARG0=$_[ARG0] ARG1=$_[ARG1]"
              );
              unless ($_[ARG0] eq 'accept' and $_[ARG1] == ECONNABORTED) {
                $client_error->(@_);
                if ($_[HEAP]->{shutdown_on_error}) {
                  $_[HEAP]->{got_an_error} = 1;
                  $_[KERNEL]->yield("shutdown");
                }
              }
            },
            tcp_server_got_flush => sub {
              my $heap = $_[HEAP];
              DEBUG and warn "$$: $alias child Flush";
              $client_flushed->(@_);
              if ($heap->{shutdown}) {
                DEBUG and warn "$$: $alias child Flush, callback";
                $client_disconnected->(@_);
                delete $heap->{client};
              }
            },
            shutdown => sub {
              DEBUG and warn "$$: $alias child Shutdown";
              my $heap = $_[HEAP];
              $heap->{shutdown} = 1;
              if (defined $heap->{client}) {
                if (
                  $heap->{got_an_error} or
                  not $heap->{client}->get_driver_out_octets()
                ) {
                  DEBUG and warn "$$: $alias child Shutdown, callback";
                  $client_disconnected->(@_);
                  delete $heap->{client};
                }
              }
            },
            _stop => sub {
              ## concurrency on close
              DEBUG and warn(
                "$$: $alias _stop accept_session = $accept_session_id"
              );
              if( defined $accept_session_id ) {
                $_[KERNEL]->call( $accept_session_id, 'disconnected' );
              }
              else {
                # This means that the Server::TCP was shutdown before
                # this connection closed.  So it doesn't really matter that
                # we can't decrement the connection counter.
                DEBUG and warn(
                  "$$: $_[HEAP]->{alias} Disconnected from a connection ",
                  "without POE::Component::Server::TCP parent"
                );
              }
              return;
            },

            # User supplied states.
            %$inline_states
          },

          # More user supplied states.
          package_states => $package_states,
          object_states  => $object_states,

          args => [ $socket, $args ],
        );
      };
    }
  };

  # Complain about strange things we're given.
  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  ## verify concurrency on accept
  my $orig_accept_callback = $accept_callback;
  $accept_callback = sub {
    $_[HEAP]->{connections}++;
    DEBUG and warn(
      "$$: $_[HEAP]->{alias} Connection opened ",
      "($_[HEAP]->{connections} open)"
    );
    if( $_[HEAP]->{concurrency} != -1 and $_[HEAP]->{listener} ) {
      if( $_[HEAP]->{connections} >= $_[HEAP]->{concurrency} ) {
        DEBUG and warn(
          "$$: $_[HEAP]->{alias} Concurrent connection limit reached, ",
          "pausing accept"
        );
        $_[HEAP]->{listener}->pause_accept()
      }
    }
    $orig_accept_callback->(@_);
  };

  # Create the session, at long last.
  # This is done inline so that closures can customize it.
  # We save the accept session's ID to avoid self reference.

  $accept_session_id = $session_type->create(
    @$session_params,
    inline_states => {
      _start => sub {
        if (defined $alias) {
          $_[HEAP]->{alias} = $alias;
          $_[KERNEL]->alias_set( $alias );
        }

        $_[HEAP]->{concurrency} = $concurrency;
        $_[HEAP]->{connections} = 0;

        $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new(
          ( ($domain == AF_UNIX or $domain == PF_UNIX)
            ? ()
            : ( BindPort => $port )
          ),
          BindAddress  => $address,
          SocketDomain => $domain,
          Reuse        => 'yes',
          SuccessEvent => 'tcp_server_got_connection',
          FailureEvent => 'tcp_server_got_error',
        );
        $server_started->(@_);
      },
      # Catch an error.
      tcp_server_got_error => $error_callback,

      # We accepted a connection.  Do something with it.
      tcp_server_got_connection => $accept_callback,

      # conncurrency on close.
      disconnected => sub {
        $_[HEAP]->{connections}--;
        DEBUG and warn(
          "$$: $_[HEAP]->{alias} Connection closed ",
          "($_[HEAP]->{connections} open)"
        );
        if ($_[HEAP]->{connections} < 0) {
          warn(
            "Excessive 'disconnected' event ",
            "from $_[CALLER_FILE] at line $_[CALLER_LINE]\n"
          );
          $_[HEAP]->{connections} = 0;
        }
        if( $_[HEAP]->{concurrency} != -1 and $_[HEAP]->{listener} ) {
          if( $_[HEAP]->{connections} == ($_[HEAP]->{concurrency}-1) ) {
            DEBUG and warn(
              "$$: $_[HEAP]->{alias} Concurrent connection limit ",
              "reestablished, resuming accept"
            );
            $_[HEAP]->{listener}->resume_accept();
          }
        }
      },

      set_concurrency => sub {
        $_[HEAP]->{concurrency} = $_[ARG0];
        DEBUG and warn(
          "$$: $_[HEAP]->{alias} Concurrent connection ",
          "limit = $_[HEAP]->{concurrency}"
        );
        if( $_[HEAP]->{concurrency} != -1 and $_[HEAP]->{listener} ) {
          if( $_[HEAP]->{connections} >= $_[HEAP]->{concurrency} ) {
            DEBUG and warn(
              "$$: $_[HEAP]->{alias} Concurrent connection limit ",
              "reached, pausing accept"
            );
            $_[HEAP]->{listener}->pause_accept()
          }
          else {
            DEBUG and warn(
              "$$: $_[HEAP]->{alias} Concurrent connection limit ",
              "reestablished, resuming accept"
            );
            $_[HEAP]->{listener}->resume_accept();
          }
        }
      },

      # Shut down.
      shutdown => sub {
        delete $_[HEAP]->{listener};
        $_[KERNEL]->alias_remove( $_[HEAP]->{alias} )
          if defined $_[HEAP]->{alias};
      },

      # Dummy states to prevent warnings.
      _stop   => sub {
        DEBUG and warn "$$: $_[HEAP]->{alias} _stop";
        undef($accept_session_id);
        return 0;
      },
      _child  => sub { },
    },

    args => $args,
  )->ID;

  # Return the session ID.
  return $accept_session_id;
}

sub _get_filters {
    my ($client_filter, $client_infilter, $client_outfilter) = @_;
    if (defined $client_infilter or defined $client_outfilter) {
      return (
        "InputFilter"  => _load_filter($client_infilter),
        "OutputFilter" => _load_filter($client_outfilter)
      );
      if (defined $client_filter) {
        carp(
          "ClientFilter ignored with ClientInputFilter or ClientOutputFilter"
        );
      }
    }
    elsif (defined $client_filter) {
     return ( "Filter" => _load_filter($client_filter) );
    }
    else {
      return ( Filter => POE::Filter::Line->new(), );
    }

}

# Get something: either arrayref, ref, or string
# Return filter
sub _load_filter {
    my $filter = shift;
    if (ref ($filter) eq 'ARRAY') {
        my @args = @$filter;
        $filter = shift @args;
        if ( _test_filter($filter) ){
            return $filter->new(@args);
        } else {
            return POE::Filter::Line->new(@args);
        }
    }
    elsif (ref $filter) {
        return $filter->clone();
    }
    else {
        if ( _test_filter($filter) ) {
            return $filter->new();
        } else {
            return POE::Filter::Line->new();
        }
    }
}

# Test if a Filter can be loaded, return success or failure
sub _test_filter {
    my $filter = shift;
    my $eval = eval {
        (my $mod = $filter) =~ s!::!/!g;
        require "$mod.pm";
        1;
    };
    if (!$eval and $@) {
        carp(
          "Failed to load [$filter]\n" .
          "Reason $@\nUsing defualt POE::Filter::Line "
        );
        return 0;
    }
    return 1;
}

# The default server error handler logs to STDERR and shuts down the
# server.

sub _default_server_error {
  warn("$$: ".
    'Server ', $_[SESSION]->ID,
    " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
  );
  delete $_[HEAP]->{listener};
}

# The default client error handler logs to STDERR

sub _default_client_error {
  my ($syscall, $errno, $error) = @_[ARG0..ARG2];
  unless ($syscall eq "read" and ($errno == 0 or $errno == ECONNRESET)) {
    $error = "(no error)" unless $errno;
    warn("$$: ".
      'Client session ', $_[SESSION]->ID,
      " got $syscall error $errno ($error)\n"
    );
  }
}

1;

__END__

=head1 NAME

POE::Component::Server::TCP - a simplified TCP server

=head1 SYNOPSIS

  #!perl

  use warnings;
  use strict;

  use POE qw(Component::Server::TCP);

  POE::Component::Server::TCP->new(
    Port => 12345,
    ClientConnected => sub {
      print "got a connection from $_[HEAP]{remote_ip}\n";
      $_[HEAP]{client}->put("Smile from the server!");
    },
    ClientInput => sub {
      my $client_input = $_[ARG0];
      $client_input =~ tr[a-zA-Z][n-za-mN-ZA-M];
      $_[HEAP]{client}->put($client_input);
    },
  );

  POE::Kernel->run;
  exit;

-><- OLD SYNOPSIS FOLLOWS
-><- This is incomplete.  I'm gutting it as things are covered.

  ### First form just accepts connections.

  my $acceptor_session_id = POE::Component::Server::TCP->new(
    Port     => $bind_port,
    Address  => $bind_address,    # Optional.
    Hostname => $bind_hostname,   # Optional.
    Domain   => AF_INET,          # Optional.
    Alias    => $session_alias,   # Optional.
    Acceptor => \&accept_handler,
    Error    => \&error_handler,  # Optional.
  );

  ### Second form also handles connections.

  my $acceptor_session_id = POE::Component::Server::TCP->new(
    Port     => $bind_port,
    Address  => $bind_address,      # Optional.
    Hostname => $bind_hostname,     # Optional.
    Domain   => AF_INET,            # Optional.
    Alias    => $session_alias,     # Optional.
    Error    => \&error_handler,    # Optional.
    Args     => [ "arg0", "arg1" ], # Optional.
    Concurrency => -1,              # Optional.

    SessionType   => "POE::Session::Abc",           # Optional.
    SessionParams => [ options => { debug => 1 } ], # Optional.

    ClientInput        => \&handle_client_input,      # Required.
    ClientConnected    => \&handle_client_connect,    # Optional.
    ClientDisconnected => \&handle_client_disconnect, # Optional.
    ClientError        => \&handle_client_error,      # Optional.
    ClientFlushed      => \&handle_client_flush,      # Optional.
    ClientFilter       => POE::Filter::Xyz->new()",   # Optional.
    ClientInputFilter  => POE::Filter::Xyz->new(),    # Optional.
    ClientOutputFilter => POE::Filter::Xyz->new(),    # Optional.
    ClientShutdownOnError => 0,                       # Optional.

    # Optionally define other states for the client session.
    InlineStates  => { ... },
    PackageStates => [ ... ],
    ObjectStates  => [ ... ],
  );

  ### Call signatures for handlers.

  sub accept_handler {
    my ($socket, $remote_address, $remote_port) = @_[ARG0, ARG1, ARG2];
  }

  sub error_handler {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_client_input {
    my $input_record = $_[ARG0];
  }

  sub handle_client_error {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
  }

  sub handle_client_connect {
    # no special parameters
  }

  sub handle_client_disconnect {
    # no special parameters
  }

  sub handle_client_flush {
    # no special parameters
  }

  ### Reserved HEAP variables:

  $heap->{listener}    = SocketFactory (only Acceptor and Error callbacks)
  $heap->{client}      = ReadWrite     (only in ClientXyz callbacks)
  $heap->{remote_ip}   = remote IP address in dotted form
  $heap->{remote_port} = remote port
  $heap->{remote_addr} = packed remote address and port
  $heap->{shutdown}    = shutdown flag (check to see if shutting down)
  $heap->{shutdown_on_error} = Automatically disconnect on error.

  ### Accepted public events.

  # Start shutting down this connection.
  $kernel->yield( "shutdown" );

  # Stop listening for connections.
  $kernel->post( server => "shutdown" );

  # Set the maximum number of simultaneous connections.
  $kernel->call( server => set_concurrency => $count );

  ### Responding to a client.

  $heap->{client}->put(@things_to_send);

=head1 DESCRIPTION

POE::Component::Server::TCP implements a generic multi-Session server.
Simple services may be put together in a few lines of code.  For
example, a server that echoes input back to the client:

  use POE qw(Component::Server::TCP);
  POE::Component::Server::TCP->new(
    Port => 12345,
    ClientInput => sub { $_[HEAP]{client}->put($_[ARG0]) },
  );
  POE::Kernel->run();

=head2 Accepting Connections Yourself

POE::Component::Server::TCP has a default mode where it accepts new
connections and creates the sessions to handle them.  Programs can do
this themselves by providing their own C<Acceptor> callbacks.  See
L</Acceptor> for details.

=head2 Master Listener Session

At creation time, POE::Component::Server::TCP starts one POE::Session
to listen for new connections.  The component's C<Alias> refers to
this master session.

If C<Acceptor> is specified, then it's up to that callback to deal
with newly accepted sockets.  Its parameters are that of
POE::Wheel::SocketFactory's C<SuccessEvent>.

Otherwise, the default C<Acceptor> callback will start a new session
to handle each connection.  These child sessions do not have their own
aliases, but their C<ClientConnected> and C<ClientDisconnected>
callbacks may register and unregister the sessions with a shared
namespace of their own.

The component's C<Started> callback is invoked at the end of the
master session's startup routine.  This callback's parameters are
the usual ones for C<_start>.

The component's C<Error> callback is invoked when the server has a
problem listening for connections.  C<Error> may also be called if the
component's default acceptor has trouble accepting a connection.
C<Error> receives the usual ones for POE::Wheel::SocketFactory and
POE::Wheel::ReadWrite L<ErrorEvent>.

=head2 Default Child Connection Sessions

If C<Acceptor> isn't specified, POE::Component::Server::TCP's default
handler will start a new session for each new client connection.  As
mentioned above, these child sessions have no aliases of their own,
but they may set aliases or register themselves another way during
their C<ClientConnected> and C<ClientDisconnected> callbacks.

It can't be stressed enough that the following callbacks are executed
within the context of dynamic child sessions---one per client
connection---and not in the master listening session.  This has been a
major point of confusion.  We welcome suggestions for making this
clearer.

TODO - Document some of the implications of having each connection
handled by a separate session.

The component's C<ClientInput> callback defines how child sessions
will handle input from their clients.  Its parameters are that of
POE::Wheel::ReadWrite's C<InputEvent>.

C<ClientConnected> is called at the end of the child session's
C<_start> routine.  In addition to the usual C<_start> parameters, it
includes the socket in $_[ARG0] and the contents of the component's
C<Args> constructor parameter in $_[ARG1].

TODO - Should C<Args> be flattened into C<ARG1..$%_>?

C<ClientDisconnected> is called when the client has disconnected,
either because the remote socket endpoint has closed or the local
endpoint has been closed by the server.  This doesn't mean the
client's session has ended, but the session most likely will very
shortly.  C<ClientDisconnected> is called from a couple disparate
places within the component, so its parameters are neither consistent
nor generally useful.

C<ClientError> is called when an error has occurred on the socket.
Its parameters are those of POE::Wheel::ReadWrite's C<ErrorEvent>.

C<ClientFlushed> is called when all pending output has been flushed to
the client socket.  Its parameters come from POE::Wheel::ReadWrite's
C<ErrorEvent>.

=head2 Performance Considerations

This ease of use comes at a price: POE::Component::Server::TCP often
performs significantly slower than a comparable server written with
POE::Wheel::SocketFactory and POE::Wheel::ReadWrite.

If performance is your primary goal, POE::Kernel's select_read() and
select_write() perform about the same as IO::Select, but your code
will be portable across every event loop POE supports.

=head2 Special Needs Considerations

POE::Component::Server::TCP is written to be easy for the most common
use cases.  Programs with more special needs should consider using
POE::Wheel::SocketFactory and POE::Wheel::ReadWrite instead.  These
are lower-level modules, and using them requires more effort.  They
are more flexible and customizable, however.

=head1 PUBLIC METHODS

=head2 Constructor

POE::Component::Server::TCP does a lot of work in its constructor.
The design goal is to push as much overhead into one-time construction
so that ongoing runtime has less overhead.  Because of this, the
server's constructor can take quite a daunting number of parameters.

POE::Component::Server::TCP always returns a POE::Session ID for the
session that will be listening for new connections.

Man of the constructor parameters have been previously described.
They are covered briefly again below.

=head3 new

new() starts a server based on POE::Component::Server::TCP and returns
a session ID for the master listening session.  All error handling is
done within the server, via the C<Error> and C<ClientError> callbacks.

The server may be shut down by posting a "shutdown" event to the
master session, either by its ID or the name given to it by the
C<Alias> parameter.

TODO - Document the shutdown procedure somewhere.

=head4 Acceptor

C<Acceptor> defines a CODE reference that POE::Wheel::SocketFactory's
C<SuccessEvent> will trigger to handle new connections.  Therefore the
parameters passed to C<Acceptor> are identical to those given to
C<SuccessEvent>.

C<Acceptor> is optional; the default handler will create a new session
for each connection.  All the "Client" constructor parameters are used
to customize this session.  In other words, C<CleintInput> and such
B<are not used when C<Acceptor> is set>.

The default C<Acceptor> adds significant convenience and flexibility
to POE::Component::Server::TCP, but it's not always a good fit for
every application.  In some cases, a custom C<Acceptor> or even
rolling one's own server with POE::Wheel::SocketFactory and
POE::Wheel::ReadWrite may be better and/or faster.

TODO - Example.

=head4 Address

C<Address> defines a single interface address the server will bind to.
It defaults to INADDR_ANY or INADDR6_ANY, when using IPv4 or IPv6,
respectively.

The value in C<Address> is passed to POE::Wheel::SocketFactory's
C<BindAddress> parameter, so it may be in whatever form that module
supports.  At the time of this writing, that may be a dotted IPv4
quad, an IPv6 address, a host name, or a packed Internet address.  See
also L</Hostname>.

TODO - Example, using the lines below.

  Address => '127.0.0.1'   # Localhost IPv4
  Address => "::1"         # Localhost IPv6

=head4 Alias

C<Alias> is an optional name that will be given to the server's master
listening session.  Events sent to this name will not be delivered to
individual connections.

The server's C<Alias> may be important if it's necessary to shut a
server down.

  sub sigusr1_handler {
    $_[KERNEL]->post(chargen_server => 'shutdown');
    $_[KERNEL]->sig_handled();
  }

=head4 ClientArgs

C<ClientArgs> is optional.  When specified, it holds an ARRAYREF that
will be passed to the C<ClientStarted> callback in $_[ARG1].
(ClientStarted's $_[ARG0] contains the newly accepted client socket.)

=head4 ClientConnected

Each new client connection is handled by a new POE::Session instance.
C<ClientConnected> is a callback that notifies the application when a
client's session is started and ready for operation.  Banners are
often sent to the remote client from this callback.

C<ClientConnected> callbacks receive the usual POE parameters plus:
The newly accepted client socket in $_[ARG0] and the ARRAYREF
specified in C<ClientArgs> in $_[ARG1].

C<ClientConnected> is called once per session startup.  It will never
be called twice for the same connection.

TODO - Example with Args and client socket examination.

=head4 ClientDisconnected

C<ClientDisconnected> is a callback that will be invoked when the
client disconnects or has been disconnected by the server.  It's
useful for cleaning up global client information, such as chat room
structures.  C<ClientDisconnected> callbacks receive the usual POE
parameters, but nothing special is included.

TODO - Example with global cleanup.

=head4 ClientError

The C<ClientError> callback is invoked when an error occurs on the
client socket.  C<ClientError> is called with POE's usual parameters,
plus the common error parameters: $_[ARG0] describes what was
happening at the time of failure.  $_[ARG1] and $_[ARG2] contain the
numeric and string versions of $!.

C<ClientError> is optional.  If omitted, POE::Component::Server::TCP
will provide a default callback that logs most errors to STDERR.

If C<ClientShutdownOnError> is set, the connection will be shut down
after C<ClientError> returns.  If C<ClientDisconnected> is specified,
it will be called as the client session is cleaned up.

C<ClientError> is triggered by POE::Wheel::ReadWrite's ErrorEvent, so
it follows that event's form.  Please see the ErrorEvent documentation
in POE::Wheel::ReadWrite for more details.

TODO - Another edit pass for clarity.

=head4 ClientFilter

C<ClientFilter> specifies the POE::Filter object or class that will
parse input from each client and serialize output before it's sent to
each client.

C<ClientFilter> may be a SCALAR, in which case it should name the
POE::Filter class to use.  Each new connection will be given a freshly
instantiated filter of that class.  No constructor parameters will be
passed.

  ClientFIlter => "POE::Filter::Stream",

Some filters require constructor parameters.  These may be specified
by an ARRAYREF.  The first element is the POE::Filter class name, and
subsequent elements are passed to the class' constructor.

  ClientFilter => [ "POE::Filter::Line", Literal => "\n" ],

C<ClientFilter> may also be given an archetypical POE::Filter OBJECT.
In this case, each new client session will receive a clone() of the
given object.

  ClientFilter => POE::Filter::Line->new(Literal => "\n"),

C<ClientFilter> is optional.  The component will use
"POE::Filter::Line" if it is omitted.

Filter modules are not automatically loaded.  Be sure that the program
loads the class before using it.

=head4 ClientInputFilter

C<ClientInputFilter> is used with C<ClientOutputFilter> to specify
different protocols for input and output.  Both must be used together.
Both follow the same usage as L</ClientFilter>.

  ClientInputFilter  => [ "POE::Filter::Line", Literal => "\n" ],
  ClientOutputFilter => 'POE::Filter::Stream',

=head4 ClientOutputFilter

C<ClientOutputFilter> is used with C<ClientInputFilter> to specify
different protocols for input and output.  Both must be used together.
Both follow the same usage as L</ClientFilter>.

  ClientInputFilter  => POE::Filter::Line->new(Literal => "\n"),
  ClientOutputFilter => 'POE::Filter::Stream',

-><- AM HERE -><-

=over 2

=item ClientInput => CODEREF

ClientInput sets a callback that will be called to handle client
input.  The callback receives its parameters directly from ReadWrite's
InputEvent.  ARG0 is the input record, and ARG1 is the wheel's unique
ID, and so on.  POE::Wheel::ReadWrite discusses input event handlers
in more detail.

  ClientInput => \&input_handler

ClientInput and Acceptor are mutually exclusive.  Enabling one
prohibits the other.

=item ClientShutdownOnError => BOOLEAN

ClientShutdownOnError tells the component whether to shut down client
sessions automatically on errors.  It defaults to true.  Setting it to
a false value (0, undef, "") turns this feature off.

If this option is turned off, it becomes your responsibility to deal
with client errors properly.  Not handling them, or not destroying
wheels when they should be, will cause the component to spit out a
constant stream of errors, eventually bogging down your application
with dead connections that spin out of control.

You've been warned.

=item Domain => SCALAR

Specifies the domain within which communication will take place.  It
selects the protocol family which should be used.  Currently supported
values are AF_INET, AF_INET6, PF_INET or PF_INET6.  This parameter is
optional and will default to AF_INET if omitted.

Note: AF_INET6 and PF_INET6 are supplied by the Socket6 module, which
is available on the CPAN.  You must have Socket6 loaded before
POE::Component::Server::TCP will create IPv6 sockets.

=item Error => CODEREF

Error sets the callback that will be invoked when the server socket
reports an error.  The callback is used to handle
POE::Wheel::SocketFactory's FailureEvent, so it receives the same
parameters as discussed there.

A default error handler will be provided if Error is omitted.  The
default handler will log the error to STDERR and shut down the server.
Active connections will have the opportunity to complete their
transactions.

=item Hostname => SCALAR

Hostname is the optional non-packed name of the interface the TCP
server will bind to. This will always be converted via inet_aton
and so can either be a dotted quad or a name. If you know that you
are passing in text, then this parameter should be used in preference
to Address, to prevent confusion in the case that the hostname
happens to be 4 bytes in length. In the case that both are
provided, then the Address parameter overrides
the Hostname parameter.

=item InlineStates => HASHREF

InlineStates holds a hashref of callbacks to handle custom events.
The hashref follows the same form as POE::Session->create()'s
inline_states parameter.

=item ObjectStates => ARRAYREF

ObjectStates holds a list reference of objects and the events they
handle.  The ARRAYREF follows the same form as POE::Session->create()'s
object_states parameter.

=item PackageStates => ARRAYREF

PackageStates holds a list reference of Perl package names and the
events they handle.  The ARRAYREF follows the same form as
POE::Session->create()'s package_states parameter.

=item Port => SCALAR

Port contains the port the listening socket will be bound to.  It
defaults to INADDR_ANY, which usually lets the operating system pick a
port at random.

  Port => 30023

=item SessionParams => ARRAYREF

SessionParams specifies additional parameters that will be passed to
the SessionType constructor at creation time.  It must be an array
reference.

  SessionParams => [ options => { debug => 1, trace => 1 } ],

It is important to realize that some of the arguments to
SessionHandler may get clobbered when defining them for your
SessionHandler.  It is advised that you stick to defining arguments in
the "options" hash such as trace and debug. See L<POE::Session> for an
example list of options.

=item SessionType => SCALAR

SessionType specifies what type of sessions will be created within the
TCP server.  It must be a scalar value.

  SessionType => "POE::Session::MultiDispatch"

SessionType is optional.  The component will create POE::Session
instances if a new type isn't specified.

=item Started => CODEREF

Started sets a callback that will be invoked within the main server
session's context.  It notifies your code that the server has started.
Its parameters are the usual for a session's _start handler.

Started is optional.

=item Concurrency => SCALAR

Controls the number of connections that may be open at the same time.
Defaults to -1, which means unlimited number of simultaneous connections.
0 means no connections.  This value may be set via the
C<set_concurrency> event, see L<EVENTS>.

Note that if you define the C<Acceptor> callback, you will have to inform
the TCP server session that a connection was closed. This is done by sending
a C<disconnected> event to your session's parent. This is only necessary if
you define an C<Acceptor> callback.  For C<ClientInput>, it's all handled
for you.

Example:

  Acceptor => sub {
    # ....
    POE::Session->create(
      # ....
      inline_states => {
        _start => sub {
          # ....
          # remember who our parent is
          $_[HEAP]->{server_tcp} = $_[SENDER]->ID;
          # ....
        },
        got_client_disconnect => sub {
          # ....
          $_[KERNEL]->post( $_[HEAP]->{server_tcp} => 'disconnected' );
          # ....
        }
      }
    );
  }

=back

=head1 EVENTS

It's possible to manipulate a TCP server component by sending it
messages.

=over 2

=item shutdown

Shuts down the TCP server.  This entails destroying the SocketFactory
that's listening for connections and removing the TCP server's alias,
if one is set.

Active connections are not shut down until they disconnect.

=item disconnected

Inform the TCP server that a connection was closed.  This is only necessary
when using C<Concurrency> is set and you are using an L<Acceptor> callback.

=item set_concurrency

Set the number of simultaneous connections.  See L<Concurrency> above.

  $kernel->call( "tcp_server_alias", "set_concurrency", $max_count );

=back

=head1 SEE ALSO

POE::Component::Client::TCP, POE::Wheel::SocketFactory,
POE::Wheel::ReadWrite, POE::Filter

=head1 BUGS

This looks nothing like what Ann envisioned.

This component currently does not accept many of the options that
POE::Wheel::SocketFactory does.

This component will not bind to several addresses at once.  This may
be a limitation in SocketFactory, but it's not by design.

This component needs more complex error handling which appends for
construction errors and replaces for runtime errors, instead of
replacing for all.

Some use cases require different session classes for the listener and
the connection handlers.  This isn't currently supported.  Please send
patches. :)

TODO - Rename C<Args> into C<ClientArgs>.

TODO - Document that Reuse is set implicitly.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Server::TCP is Copyright 2000-2006 by Rocco Caputo.
All rights are reserved.  POE::Component::Server::TCP is free
software, and it may be redistributed and/or modified under the same
terms as Perl itself.

POE::Component::Server::TCP is based on code, used with permission,
from Ann Barcomb E<lt>kudra@domaintje.comE<gt>.

POE::Component::Server::TCP is based on code, used with permission,
from Jos Boumans E<lt>kane@cpan.orgE<gt>.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
