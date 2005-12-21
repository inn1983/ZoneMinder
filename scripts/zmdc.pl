#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Daemon Control Script, $Date$, $Revision$
# Copyright (C) 2003, 2004, 2005  Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================
#
# This script is the gateway for controlling the various ZoneMinder
# daemons. All starting, stopping and restarting goes through here.
# On the first invocation it starts up a server which subsequently
# records what's running and what's not. Other invocations just 
# connect to the server and pass instructions to it.
#
use strict;
use bytes;

# ==========================================================================
#
# User config
#
# ==========================================================================

use constant DBG_ID => "zmdc"; # Tag that appears in debug to identify source
use constant DBG_LEVEL => 0; # 0 is errors, warnings and info only, > 0 for debug

use constant MAX_CONNECT_DELAY => 10;

# ==========================================================================
#
# Don't change anything from here on down
#
# ==========================================================================

use ZoneMinder;
use POSIX;
use Socket;
use IO::Handle;
use Data::Dumper;

use constant DC_SOCK_FILE => ZM_PATH_SOCKS.'/zmdc.sock';
use constant DC_LOG_FILE => ZM_PATH_LOGS.'/zmdc.log';

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

zmDbgInit( DBG_ID, DBG_LEVEL );

my @daemons = ( 'zmc', 'zma', 'zmf', 'zmfilter.pl', 'zmaudit.pl', 'zmtrigger.pl', 'zmx10.pl', 'zmwatch.pl', 'zmupdate.pl', 'zmtrack.pl' );

my $command = shift @ARGV;
die( "No command given" ) unless( $command );
my $needs_daemon = $command !~ /(?:shutdown|status|check)/;
my $daemon = shift( @ARGV );
die( "No daemon given" ) unless( !$needs_daemon || $daemon );
my @args;

my $daemon_patt = '('.join( '|', @daemons ).')';
if ( $needs_daemon )
{
	if ( $daemon =~ /^${daemon_patt}$/ )
	{
		$daemon = $1;
	}
	else
	{
		die( "Invalid daemon '$daemon' specified" );
	}
}

foreach my $arg ( @ARGV )
{
	# Detaint arguments, if they look ok
	#if ( $arg =~ /^(-{0,2}[\w]+)/ )
	if ( $arg =~ /^(-{0,2}[\w\/?&=.-]+)$/ )
	{
		push( @args, $1 );
	}
	else
	{
		die( "Bogus argument '$arg' found" );
	}
}

socket( CLIENT, PF_UNIX, SOCK_STREAM, 0 ) or die( "Can't open socket: $!" );

my $saddr = sockaddr_un( DC_SOCK_FILE );

if ( !connect( CLIENT, $saddr ) )
{
	if ( $command eq "check" )
	{
		print( "stopped\n" );
		exit();
	}
	# The server isn't there 
	print( "Unable to connect, starting server\n" );
	close( CLIENT );

	if ( my $cpid = fork() )
	{
		# Parent process just sleep and fall through
		socket( CLIENT, PF_UNIX, SOCK_STREAM, 0 ) or die( "Can't open socket: $!" );
		my $attempts = 0;
		while (!connect( CLIENT, $saddr ))
		{
			$attempts++;
			die( "Can't connect: $!" ) if ($attempts > MAX_CONNECT_DELAY);
			sleep(1);
		}
	}
	elsif ( defined($cpid) )
	{
		setpgrp();

		open( LOG, ">>".DC_LOG_FILE ) or die( "Can't open log file: $!" );
		open(STDOUT, ">&LOG") || die( "Can't dup stdout: $!" );
		select( STDOUT ); $| = 1;
		open(STDERR, ">&LOG") || die( "Can't dup stderr: $!" );
		select( STDERR ); $| = 1;
		select( LOG ); $| = 1;

		dprint( "Server starting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );

		kill_all( 1 );

		socket( SERVER, PF_UNIX, SOCK_STREAM, 0 ) or Fatal( "Can't open socket: $!" );
		unlink( DC_SOCK_FILE );
		bind( SERVER, $saddr ) or Fatal( "Can't bind: $!" );
		listen( SERVER, SOMAXCONN ) or Fatal( "Can't listen: $!" );

		$SIG{CHLD} = \&reaper;
		$SIG{INT} = \&shutdown_all;
		$SIG{TERM} = \&shutdown_all;
		$SIG{ABRT} = \&shutdown_all;
		$SIG{HUP} = \&status;

		my %cmd_hash;
		my %pid_hash;

		sub cprint
		{
			if ( fileno(CLIENT) )
			{
				print CLIENT @_
			}
		}
		sub dprint
		{
			if ( fileno(CLIENT) )
			{
				print CLIENT @_
			}
			Info( @_ );
		}
		sub start
		{
			my $daemon = shift;
			my @args = @_;

			my $command = $daemon;
			$command .= ' '.join( ' ', ( @args ) ) if ( @args );
			my $process = $cmd_hash{$command};

			if ( !$process )
			{
				# It's not running, or at least it's not been started by us
				$process = { daemon=>$daemon, args=>\@args, command=>$command, keepalive=>!undef };
			}
			elsif ( $process->{pid} && $pid_hash{$process->{pid}} )
			{
				dprint( "'$process->{command}' already running at ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{started}) ).", pid = $process->{pid}\n" );
				return();
			}

			if ( my $cpid = fork() )
			{
				my $sigset = POSIX::SigSet->new;
				my $blockset = POSIX::SigSet->new( SIGCHLD );
				sigprocmask( SIG_BLOCK, $blockset, $sigset ) or Fatal( "Can't block SIGCHLD: $!" );
				$process->{pid} = $cpid;
				$process->{started} = time();
				delete( $process->{pending} );

				dprint( "'$command' starting at ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{started}) ).", pid = $process->{pid}\n" );

				$cmd_hash{$process->{command}} = $pid_hash{$cpid} = $process;
				sigprocmask( SIG_SETMASK, $sigset ) or Fatal( "Can't restore SIGCHLD: $!" );
			}
			elsif ( defined($cpid ) )
			{
				# Child process
				$SIG{CHLD} = 'DEFAULT';
				$SIG{INT} = 'DEFAULT';
				$SIG{TERM} = 'DEFAULT';
				$SIG{ABRT} = 'DEFAULT';
				$SIG{HUP} = 'DEFAULT';
				dprint( "'".join( ' ', ( $daemon, @args ) )."' started at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
	
				if ( $daemon =~ /^${daemon_patt}$/ )
				{
					$daemon = ZM_PATH_BIN.'/'.$1;
				}
				else
				{
					Fatal( "Invalid daemon '$daemon' specified" );
				}

				my @good_args;
				foreach my $arg ( @args )
				{
					# Detaint arguments, if they look ok
					if ( $arg =~ /^(-{0,2}[\w\/?&=.-]+)$/ )
					{
						push( @good_args, $1 );
					}
					else
					{
						Fatal( "Bogus argument '$arg' found" );
					}
				}

				exec( $daemon, @good_args ) or Fatal( "Can't exec: $!" );
			}
			else
			{
				Fatal( "Can't fork: $!" );
			}
		}
		sub _stop
		{
			my $final = shift;
			my $daemon = shift;
			my @args = @_;

			my $command = $daemon;
			$command .= ' '.join( ' ', ( @args ) ) if ( @args );
			my $process = $cmd_hash{$command};
			if ( !$process )
			{
				dprint( "Can't find process with command of '$command'\n" );
				return();
			}
			elsif ( $process->{pending} )
			{
				delete( $cmd_hash{$command} );
				dprint( "Command '$command' removed from pending list at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
				return();
			}

			my $cpid = $process->{pid};
			if ( !$pid_hash{$cpid} )
			{
				dprint( "No process with command of '$command' is running\n" );
				return();
			}

			print( "'$daemon ".join( ' ', @args )."' stopping at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
			$process->{keepalive} = !$final;
			kill( 'TERM', $cpid );
			delete( $cmd_hash{$command} );

			# Now check it has actually gone away, if not kill -9 it
			my $count = 0;
			while( $cpid && kill( 0, $cpid ) )
			{
				if ( $count++ > 5 )
				{
					kill( 'KILL', $cpid );
				}
				sleep( 1 );
			}
		}
		sub stop
		{
			_stop( 1, @_ );
		}
		sub restart
		{
			my $daemon = shift;
			my @args = @_;

			my $command = $daemon;
			$command .= ' '.join( ' ', ( @args ) ) if ( @args );
			my $process = $cmd_hash{$command};
			if ( $process )
			{
				if ( $process->{pid} )
				{
					my $cpid = $process->{pid};
					if ( defined($pid_hash{$cpid}) )
					{
						_stop( 0, $daemon, @args );
						return;
					}
				}
			}
			start( $daemon, @args );
		}
		sub reaper
		{
			my $saved_status = $!;
			while ( (my $cpid = waitpid( -1, WNOHANG )) > 0 )
			{
				my $status = $?;

				my $process = $pid_hash{$cpid};
				delete( $pid_hash{$cpid} );

				if ( !$process )
				{
					dprint( "Can't find child with pid of '$cpid'\n" );
					next;
				}

				$process->{stopped} = time();
				$process->{runtime} = ($process->{stopped}-$process->{started});
				delete( $process->{pid} );

				my $exit_status = $status>>8;
				my $exit_signal = $status&0xfe;
				my $core_dumped = $status&0x01;

				my $out_str = "'$process->{daemon} ".join( ' ', @{$process->{args}} )."' ";
				$out_str .= ($exit_status==0)?"died":"crashed";
				$out_str .= ", exit status $exit_status" if ( $exit_status );
				$out_str .= ", signal $exit_signal" if ( $exit_signal );
				#print( ", core dumped" ) if ( $core_dumped );
				$out_str .= "\n";

				if ( $exit_status == 0 )
				{
					Info( $out_str );
				}
				else
				{
					Error( $out_str );
				}

				if ( $process->{keepalive} )
				{
					if ( !$process->{delay} || ($process->{runtime} > (10*$process->{delay})) )
					{
						#start( $process->{daemon}, @{$process->{args}} );
						# Schedule for immediate restart
						$cmd_hash{$process->{command}} = $process;
						$process->{pending} = $process->{stopped};
						$process->{delay} = 5;
					}
					else
					{
						$cmd_hash{$process->{command}} = $process;
						$process->{pending} = $process->{stopped}+$process->{delay};
						$process->{delay} *= 2;
						# Limit the start delay to 15 minutes max
						if ( $process->{delay} > ZM_MAX_RESTART_DELAY )
						{
							$process->{delay} = ZM_MAX_RESTART_DELAY;
						}
					}
				}
			}
			$SIG{CHLD} = \&reaper;
			$! = $saved_status;
		}
		sub kill_all
		{
			my $delay = shift;
			sleep( $delay );
			foreach my $daemon ( @daemons )
			{
				qx( killall --quiet --signal TERM $daemon );
			}
			sleep( $delay );
			foreach my $daemon ( @daemons )
			{
				qx( killall --quiet --signal KILL $daemon );
			}
		}
		sub restart_pending
		{
			# Restart any pending processes
			foreach my $process ( values( %cmd_hash ) )
			{
				if ( $process->{pending} && $process->{pending} <= time() )
				{
					dprint( "Starting pending process, $process->{command}\n" );
					start( $process->{daemon}, @{$process->{args}} );
				}
			}
		}
		sub shutdown_all()
		{
			foreach my $process ( values( %pid_hash ) )
			{
				stop( $process->{daemon}, @{$process->{args}} );
			}
			kill_all( 5 );
			dprint( "Server shutdown at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
			unlink( DC_SOCK_FILE );
			close( CLIENT );
			close( SERVER );
			exit();
		}
		sub check
		{
			my $daemon = shift;
			my @args = @_;

			my $command = $daemon;
			$command .= ' '.join( ' ', ( @args ) ) if ( @args );
			my $process = $cmd_hash{$command};
			if ( !$process )
			{
				cprint( "unknown\n" );
			}
			elsif ( $process->{pending} )
			{
				cprint( "pending\n" );
			}
			else
			{
				my $cpid = $process->{pid};
				if ( !$pid_hash{$cpid} )
				{
					cprint( "stopped\n" );
				}
				else
				{
					cprint( "running\n" );
				}
			}
		}
		sub status
		{
			my $daemon = shift;
			my @args = @_;

			if ( defined($daemon) )
			{
				my $command = $daemon;
				$command .= ' '.join( ' ', ( @args ) ) if ( @args );
				my $process = $cmd_hash{$command};
				if ( !$process )
				{
					dprint( "'$command' not running\n" );
					return();
				}

				if ( $process->{pending} )
				{
					dprint( "'$process->{command}' pending at ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{pending}) )."\n" );
				}
				else
				{
					my $cpid = $process->{pid};
					if ( !$pid_hash{$cpid} )
					{
						dprint( "'$command' not running\n" );
						return();
					}
				}
				dprint( "'$process->{command}' running since ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{started}) ).", pid = $process->{pid}" );
			}
			else
			{
				foreach my $process ( values(%pid_hash) )
				{
					my $out_str = "'$process->{command}' running since ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{started}) ).", pid = $process->{pid}";
					$out_str .= ", valid" if ( kill( 0, $process->{pid} ) );
					$out_str .= "\n";
					dprint( $out_str );
				}
				foreach my $process ( values( %cmd_hash ) )
				{
					if ( $process->{pending} )
					{
						dprint( "'$process->{command}' pending at ".strftime( '%y/%m/%d %H:%M:%S', localtime( $process->{pending}) )."\n" );
					}
				}
			}
		}

		my $rin = '';
		vec( $rin, fileno(SERVER), 1 ) = 1;
		my $win = $rin;
		my $ein = $win;
		my $timeout = 1;
		while( 1 )
		{
			my $nfound = select( my $rout = $rin, undef, undef, $timeout );
			if ( $nfound > 0 )
			{
				if ( vec( $rout, fileno(SERVER), 1 ) )
				{
					my $paddr = accept( CLIENT, SERVER );
					my $message = <CLIENT>;

					next if ( !$message );

					my ( $command, $daemon, @args ) = split( ';', $message );

					if ( $command eq 'start' )
					{
						start( $daemon, @args );
					}
					elsif ( $command eq 'stop' )
					{
						stop( $daemon, @args );
					}
					elsif ( $command eq 'restart' )
					{
						restart( $daemon, @args );
					}
					elsif ( $command eq 'shutdown' )
					{
						shutdown_all();
					}
					elsif ( $command eq 'check' )
					{
						check( $daemon, @args );
					}
					elsif ( $command eq 'status' )
					{
						if ( $daemon )
						{
							status( $daemon, @args );
						}
						else
						{
							status();
						}
					}
					else
					{
						dprint( "Invalid command '$command'\n" );
					}
					close( CLIENT );
				}
				else
				{
					Fatal( "Bogus descriptor" );
				}
			}
			elsif ( $nfound < 0 )
			{
					print( "Got: $nfound - $!\n" );
				if ( $! == EINTR )
				{
					# Dead child, will be reaped
					#print( "Probable dead child\n" );
					# See if it needs to start up again
					restart_pending();
				}
				elsif ( $! == EPIPE )
				{
					Error( "Can't select: $!" );
				}
				else
				{
					Fatal( "Can't select: $!" );
				}
			}
			else
			{
				#print( "Select timed out\n" );
				restart_pending();
			}
		}
		dprint( "Server exiting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
		close( LOG );
		exit();
	}
	else
	{
		Fatal( "Can't fork: $!" );
	}
}
if ( $command eq "check" && !$daemon )
{
	print( "running\n" );
	exit();
}
# The server is there, connect to it
#print( "Writing commands\n" );
CLIENT->autoflush();
my $message = "$command";
$message .= ";$daemon" if ( $daemon );
$message .= ";".join( ';', @args ) if ( @args );
print( CLIENT $message );
shutdown( CLIENT, 1 );
while ( my $line = <CLIENT> )
{
	chomp( $line );
	print( "$line\n" );
}
close( CLIENT );
#print( "Finished writing, bye\n" );