# $Id$

# IO::Poll substrate for POE::Kernel.  The theory is that this will be
# faster for large scale applications.  This file is contributed by
# Matt Sergeant (baud).

# Empty package to appease perl.
package POE::Kernel::Poll;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

# Everything plugs into POE::Kernel;
package POE::Kernel;
use POE::Preprocessor;

use strict;

# Ensure that no other substrate module has been loaded.
BEGIN {
  die "POE can't use IO::Poll and " . &POE_SUBSTRATE_NAME . "\n"
    if defined &POE_SUBSTRATE;
  die "IO::Poll is version $IO::Poll::VERSION (POE needs 0.05 or newer)\n"
    if $IO::Poll::VERSION < 0.05;
};

# Declare the substrate we're using.
sub POE_SUBSTRATE      () { SUBSTRATE_POLL      }
sub POE_SUBSTRATE_NAME () { SUBSTRATE_NAME_POLL }

use IO::Poll qw( POLLRDNORM POLLWRNORM POLLRDBAND
                 POLLIN POLLOUT POLLERR POLLHUP
               );

sub MINIMUM_POLL_TIMEOUT () { 0 }

#------------------------------------------------------------------------------
# Signal handlers.

sub _substrate_signal_handler_generic {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing generic SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
  $SIG{$_[0]} = \&_substrate_signal_handler_generic;
}

sub _substrate_signal_handler_pipe {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing PIPE-like SIG$_[0] event...\n";
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SIGNAL, ET_SIGNAL,
      [ $_[0] ],
      time(), __FILE__, __LINE__
    );
    $SIG{$_[0]} = \&_substrate_signal_handler_pipe;
}

# Special handler.  Stop watching for children; instead, start a loop
# that polls for them.
sub _substrate_signal_handler_child {
  TRACE_SIGNALS and warn "\%\%\% Enqueuing CHLD-like SIG$_[0] event...\n";
  $SIG{$_[0]} = 'DEFAULT';
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
      time(), __FILE__, __LINE__
    );
}

#------------------------------------------------------------------------------
# Signal handler maintenance macros.

macro substrate_watch_signal {
  # Child process has stopped.
  if ($signal eq 'CHLD' or $signal eq 'CLD') {

    # Begin constant polling loop.  Only start it on CHLD or on CLD if
    # CHLD doesn't exist.
    $SIG{$signal} = 'DEFAULT';
    $poe_kernel->_enqueue_event
      ( $poe_kernel, $poe_kernel,
        EN_SCPOLL, ET_SCPOLL,
        [ ],
        time() + 1, __FILE__, __LINE__
      ) if $signal eq 'CHLD' or not exists $SIG{CHLD};

    next;
  }

  # Broken pipe.
  if ($signal eq 'PIPE') {
    $SIG{$signal} = \&_substrate_signal_handler_pipe;
    next;
  }

  # Artur Bergman (sky) noticed that xterm resizing can generate a LOT
  # of WINCH signals.  That rapidly crashes perl, which, with the help
  # of most libc's, can't handle signals well at all.  We ignore
  # WINCH, therefore.
  next if $signal eq 'WINCH';

  # Everything else.
  $SIG{$signal} = \&_substrate_signal_handler_generic;
}

macro substrate_resume_watching_child_signals {
  $SIG{CHLD} = 'DEFAULT' if exists $SIG{CHLD};
  $SIG{CLD}  = 'DEFAULT' if exists $SIG{CLD};
  $poe_kernel->_enqueue_event
    ( $poe_kernel, $poe_kernel,
      EN_SCPOLL, ET_SCPOLL, [ ],
      time() + 1, __FILE__, __LINE__
    ) if keys(%kr_sessions) > 1;
}

#------------------------------------------------------------------------------
# Event watchers and callbacks.

### Time.

macro substrate_resume_time_watcher {
  # does nothing
}

macro substrate_reset_time_watcher {
  # does nothing
}

macro substrate_pause_time_watcher {
  # does nothing
}

sub vec_to_poll {
  return POLLIN     if $_[0] == VEC_RD;
  return POLLOUT    if $_[0] == VEC_WR;
  return POLLRDBAND if $_[0] == VEC_EX;
  croak "unknown I/O vector $_[0]";
}

### Filehandles.

macro substrate_watch_filehandle (<fileno>,<vector>) {
  my $type = vec_to_poll(<vector>);
  my $current = $POE::Kernel::Poll::poll_fd_masks{<fileno>} || 0;
  my $new = $current | $type;

  TRACE_SELECT and
    warn( sprintf( "Watch " . <fileno> .
                   ": Current mask: 0x%02X - including 0x%02X = 0x%02X\n",
                   $current, $type, $new
                 )
        );

  $POE::Kernel::Poll::poll_fd_masks{<fileno>} = $new;

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_RUNNING;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_RUNNING;
}

macro substrate_ignore_filehandle (<fileno>,<vector>) {
  my $type = vec_to_poll(<vector>);
  my $current = $POE::Kernel::Poll::poll_fd_masks{<fileno>} || 0;
  my $new = $current & ~$type;

  TRACE_SELECT and
    warn( sprintf( "Ignore ". <fileno> .
                   ": Current mask: 0x%02X - removing 0x%02X = 0x%02X\n",
                   $current, $type, $new
                 )
        );

  if ($new) {
    $POE::Kernel::Poll::poll_fd_masks{<fileno>} = $new;
  }
  else {
    delete $POE::Kernel::Poll::poll_fd_masks{<fileno>};
  }

  $kr_fno_vec->[FVC_ST_ACTUAL]  = HS_STOPPED;
  $kr_fno_vec->[FVC_ST_REQUEST] = HS_STOPPED;
}

macro substrate_pause_filehandle_watcher (<fileno>,<vector>) {
  my $type = vec_to_poll(<vector>);
  my $current = $POE::Kernel::Poll::poll_fd_masks{<fileno>} || 0;
  my $new = $current & ~$type;

  TRACE_SELECT and
    warn( sprintf( "Pause " . <fileno> .
                   ": Current mask: 0x%02X - removing 0x%02X = 0x%02X\n",
                   $current, $type, $new
                 )
        );

  if ($new) {
    $POE::Kernel::Poll::poll_fd_masks{<fileno>} = $new;
  }
  else {
    delete $POE::Kernel::Poll::poll_fd_masks{<fileno>};
  }

  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_PAUSED;
}

macro substrate_resume_filehandle_watcher (<fileno>,<vector>) {
  my $type = vec_to_poll(<vector>);
  my $current = $POE::Kernel::Poll::poll_fd_masks{<fileno>} || 0;
  my $new = $current | $type;

  TRACE_SELECT and
    warn( sprintf( "Resume " . <fileno> .
                   ": Current mask: 0x%02X - including 0x%02X = 0x%02X\n",
                   $current, $type, $new
                 )
        );

  $POE::Kernel::Poll::poll_fd_masks{<fileno>} = $new;

  $kr_fno_vec->[FVC_ST_ACTUAL] = HS_RUNNING;
}

macro substrate_define_callbacks {
  # does nothing
}

#------------------------------------------------------------------------------
# Main loop management.

macro substrate_init_main_loop {
  %POE::Kernel::Poll::poll_fd_masks = ();
}

macro substrate_do_timeslice {
  # Check for a hung kernel.
  {% test_for_idle_poe_kernel %}

  # Set the poll timeout based on current queue conditions.  If there
  # are FIFO events, then the poll timeout is zero and move on.
  # Otherwise set the poll timeout until the next pending event, if
  # there are any.  If nothing is waiting, set the timeout for some
  # constant number of seconds.

  my $now = time();
  my $timeout;

  if (@kr_events) {
    $timeout = $kr_events[0]->[ST_TIME] - $now;
    $timeout = MINIMUM_POLL_TIMEOUT if $timeout < MINIMUM_POLL_TIMEOUT;
  }
  else {
    $timeout = 3600;
  }

  if (TRACE_QUEUE) {
    warn( '*** Kernel::run() iterating.  ' .
          sprintf("now(%.4f) timeout(%.4f) then(%.4f)\n",
                  $now-$^T, $timeout, ($now-$^T)+$timeout
                 )
        );
    warn( '*** Event times: ' .
          join( ', ',
                map { sprintf('%d=%.4f',
                              $_->[ST_SEQ], $_->[ST_TIME] - $now
                             )
                    } @kr_events
              ) .
          "\n"
        );
  }

  # Ensure that the event queue remains in time order.
  if (ASSERT_EVENTS and @kr_events) {
    my $previous_time = $kr_events[0]->[ST_TIME];
    foreach (@kr_events) {
      die "event $_->[ST_SEQ] is out of order"
        if $_->[ST_TIME] < $previous_time;
      $previous_time = $_->[ST_TIME];
    }
  }

  @filenos = %POE::Kernel::Poll::poll_fd_masks;

  if (TRACE_SELECT) {
    foreach (sort { $a<=>$b} keys %POE::Kernel::Poll::poll_fd_masks) {
      my @types;
      push @types, "plain-file"        if -f;
      push @types, "directory"         if -d;
      push @types, "symlink"           if -l;
      push @types, "pipe"              if -p;
      push @types, "socket"            if -S;
      push @types, "block-special"     if -b;
      push @types, "character-special" if -c;
      push @types, "tty"               if -t;
      my @modes;
      my $flags = $POE::Kernel::Poll::poll_fd_masks{$_};
      push @modes, 'r' if $flags & (POLLIN | POLLHUP | POLLERR);
      push @modes, 'w' if $flags & (POLLOUT | POLLHUP | POLLERR);
      push @modes, 'x' if $flags & (POLLRDBAND | POLLHUP | POLLERR);
      warn( "file descriptor $_ = modes(@modes) types(@types)\n" );
    }
  }

  # Avoid looking at filehandles if we don't need to.  -><- The added
  # code to make this sleep is non-optimal.  There is a way to do this
  # in fewer tests.

  if ($timeout or @filenos) {

    # There are filehandles to poll, so do so.

    if (@filenos) {
      # Check filehandles, or wait for a period of time to elapse.
      my $hits = IO::Poll::_poll($timeout * 1000, @filenos);

      if (ASSERT_SELECT) {
        if ($hits < 0) {
          confess "poll returned $hits (error): $!"
            unless ( ($! == EINPROGRESS) or
                     ($! == EWOULDBLOCK) or
                     ($! == EINTR)
                   );
        }
      }

      if (TRACE_SELECT) {
        if ($hits > 0) {
          warn "poll hits = $hits\n";
        }
        elsif ($hits == 0) {
          warn "poll timed out...\n";
        }
      }

      # If poll has seen filehandle activity, then gather up the
      # active filehandles and synchronously dispatch events to the
      # appropriate handlers.

      if ($hits > 0) {

        # This is where they're gathered.

        while (@filenos) {
          my ($fd, $got_mask) = splice(@filenos, 0, 2);
          next unless $got_mask;

          my $watch_mask = $POE::Kernel::Poll::poll_fd_masks{$fd};
          if ( $watch_mask & POLLIN and
               $got_mask & (POLLIN | POLLHUP | POLLERR)
             ) {
            TRACE_SELECT and warn "enqueuing read for fileno $fd\n";
            {% enqueue_ready_selects $fd, VEC_RD %}
          }

          if ( $watch_mask & POLLOUT and
               $got_mask & (POLLOUT | POLLHUP | POLLERR)
             ) {
            TRACE_SELECT and warn "enqueuing write for fileno $fd\n";
            {% enqueue_ready_selects $fd, VEC_WR %}
          }

          if ( $watch_mask & POLLRDBAND and
               $got_mask & (POLLRDBAND | POLLHUP | POLLERR)
             ) {
            TRACE_SELECT and warn "enqueuing expedite for fileno $fd\n";
            {% enqueue_ready_selects $fd, VEC_EX %}
          }
        }
      }
    }

    # No filehandles to poll on.  Try to sleep instead.  Use sleep()
    # itself on MSWin32.  Use a dummy four-argument select() everywhere
    # else.

    else {
      if ($^O eq 'MSWin32') {
        sleep($timeout);
      }
      else {
        select(undef, undef, undef, $timeout);
      }
    }
  }

  # Dispatch whatever events are due.

  $now = time();
  while ( @kr_events and ($kr_events[0]->[ST_TIME] <= $now) ) {
    my $event;

    if (TRACE_QUEUE) {
      $event = $kr_events[0];
      warn( sprintf('now(%.4f) ', $now - $^T) .
            sprintf('sched_time(%.4f)  ', $event->[ST_TIME] - $^T) .
            "seq($event->[ST_SEQ])  " .
            "name($event->[ST_NAME])\n"
          );
    }

    # Pull an event off the queue, and dispatch it.
    $event = shift @kr_events;
    delete $kr_event_ids{$event->[ST_SEQ]};
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}
    {% ses_refcount_dec2 $event->[ST_SOURCE], SS_POST_COUNT %}
    $self->_dispatch_event(@$event);
  }
}

macro substrate_main_loop {
  # Run for as long as there are sessions to service.
  while (keys %kr_sessions) {
    {% substrate_do_timeslice %}
  }
}

macro substrate_stop_main_loop {
  # does nothing
}

sub signal_ui_destroy {
  # does nothing
}

1;
