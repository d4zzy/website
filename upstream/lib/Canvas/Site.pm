#
# Copyright (C) 2013    Ian Firns   <firnsy@kororaproject.org>
#                       Chris Smart <csmart@kororaproject.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
package Canvas::Site;

use warnings;
use strict;

use Mojo::Base 'Mojolicious::Controller';

#
# PERL INCLUDES
#
use Data::Dumper;
use Mojo::Util qw(b64_encode url_escape url_unescape);

#
# LOCAL INCLUDES
#
use Canvas::Store::User;
use Canvas::Store::UserMeta;

#
# INTERNAL HELPERS
#

#
# create_auth_token()
#
sub create_auth_token {
  open( DEV, "/dev/urandom" ) or die "Cannot open file: $!";
  read( DEV, my $bytes, 48 );

  close( DEV );
  my $token = b64_encode( $bytes );
  chomp $token;

  return $token;
}


#
# controller handlers
#
sub index {
  my $self = shift;

  #return $self->redirect_to('login') unless( $self->is_user_authenticated );

  $self->render('index');
}

sub discover {
  my $self = shift;

  $self->render('discover');
}

sub download {
  my $self = shift;

  $self->render('download');
}

sub login {
  my $self = shift;

  $self->render('login');
}

sub auth {
  my $self = shift;
  my $json = Mojo::JSON->new;
  my $data = $json->decode($self->req->body);

  # collect first out of the parameters and then json decoded body
  my $u = $self->param('u') // $data->{u} // '';
  my $p = $self->param('p') // $data->{p} // '';

  if( $self->authenticate($u, $p) ) {
  }

  # extract the redirect url and fall back to the index
  my $url = $self->param('redirect_to') // $data->{redirect_to} // '/';

  return $self->redirect_to( $url );
};

sub deauth {
  my $self = shift;

  $self->logout;

  # extract the redirect url and fall back to the index
  my $url = $self->param('redirect_to') // '/';

  return $self->redirect_to( $url );
};

sub activated {
  my $self = shift;

  my $username = $self->flash('username');

  return $self->redirect_to( '/' ) unless defined $username;

  $self->stash( username => $username );
  $self->render('activated');
}

sub activate_get {
  my $self = shift;

  my $suffix = $self->param('token');
  my $username = $self->param('username');

  # lookup the requested account for activation
  my $u = Canvas::Store::User->search({ username => $username })->first;

  # redirect to home unless account and activation token suffix exists
  return $self->redirect_to('/') unless(
    defined $u &&
    defined $suffix
  );

  $self->stash( username => $username );
  $self->render('activate');
}

sub activate_post {
  my $self = shift;

  my $username = $self->param('username');
  my $prefix = $self->param('prefix');
  my $suffix = $self->param('token');

  # lookup the requested account for activation
  my $u = Canvas::Store::User->search({ username => $username })->first;

  # redirect to home unless account and activation token prefix/suffix exists
  return $self->redirect_to('/') unless(
    defined $u &&
    defined $prefix &&
    defined $suffix
  );

  # TODO: check account age

  # build the supplied token and fetch the stored token
  my $token_supplied = $prefix . url_unescape( $suffix );
  my $token = url_unescape( $u->metadata('activation_token') // '' );

  # redirect to home unless supplied and stored tokens match
  return $self->redirect_to('/') unless $token eq $token_supplied;

  $u->status('active');
  $u->update;

  $u->metadata_clear('activation_token');

  $self->flash( username => $username );

  $self->redirect_to('/activated');
}

sub registered {
  my $self = shift;

  my $url  = $self->flash('redirect_to');

  return $self->redirect_to( '/' ) unless defined $url;

  $self->stash( redirect_to => $url );
  $self->render('registered');
}

sub register_get {
  my $self = shift;

  my $error = $self->flash('error') // { code => 0, message => '' };
  my $values = $self->flash('values') // { user => '', email => '' };

  $self->stash( error => $error, values => $values );

  $self->render('register');
}

sub register_post {
  my $self = shift;

  # extract the redirect url and fall back to the index
  my $url = $self->param('redirect_to') // '/';

  # grab registration details
  my $user = $self->param('user');
  my $pass = $self->param('pass');
  my $pass_confirm = $self->param('confirm');
  my $email = $self->param('email');

  # flash the redirect and previous values for future redirects
  $self->flash(
    redirect_to => $url,
    values      => { user => $user, email => $email }
  );

  # validate username
  unless( $user =~ m/^[a-zA-Z0-9_]+$/ ) {
    $self->flash( error => { code => 1, message => 'Your username can only consist of alphanumeric characters and underscores only [A-Z, a-z, 0-9, _].' });

    return $self->redirect_to('/register');
  }

  # validate user name is available
  my $u = Canvas::Store::User->search({
    username => $user,
  })->first;

  if( defined $u ) {
    $self->flash( error => { code => 2, message => 'That username already exists.' } );

    return $self->redirect_to('/register');
  }

  # validate email address
  unless( $email =~ m/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$/ ) {
    $self->flash( error => { code => 3, message => 'Your email address is invalid.' });

    return $self->redirect_to('/register');
  }

  # validate passwords have sufficient length
  if( length $pass < 8 ) {
    $self->flash( error => { code => 4, message => 'Your password must be at least 8 characters long.' });

    return $self->redirect_to('/register');
  }

  # validate passwords match
  if( $pass ne $pass_confirm ) {
    $self->flash( error => { code => 5, message => 'Your passwords don\'t match.' } );

    return $self->redirect_to('/register');
  };

  $u = Canvas::Store::User->create({
    username  => $user,
    email     => $email,
  });

  my $message = '';

  if( defined $u ) {
    # store password as a salted hash
    $u->password( $u->hash_password( $pass ) );
    $u->update;

    # generate activiation token
    my $token = create_auth_token;

    my $um = Canvas::Store::UserMeta->create({
      user_id     => $u->id,
      meta_key    => 'activation_token',
      meta_value  => url_escape $token,
    });

    my $activation_key = substr( $token, 0, 31 );
    my $activation_url = 'https://kororaproject.org/activate/' . $user . '?token=' . url_escape substr( $token, 31 );

    $message = "" .
      "G'day,\n\n" .
      "Thank you for registering to be part of our Korora community.\n\n".
      "Your activiation key is: " . $activation_key . "\n\n" .
      "In order to activate your Korora Prime account, copy your activation key and follow the prompts at: " . $activation_url . "\n\n" .
      "Please note that you must activate your account within 24 hours.\n\n" .
#      "If you have any questions regarding his process, click 'Reply' in your email client and we'll be only too happy to help.\n\n" .
      "Regards,\n" .
      "The Korora Team.\n";

    # send the activiation email
    $self->mail(
      to      => $email,
      from    => 'accounts@kororaproject.org',
      subject => 'Korora Project - Prime Registration',
      data    => $message,
    );
  }

  $self->redirect_to('/registered');
}


#
# CATCH ALL
sub trap {
  my $self = shift;

  my $path = $self->param('trap');

  # HTML5 mode forwarding based on valid paths
  $self->redirect_to('/#!/' . $path);
};



1;
