package Zing::Store::Mysql;

use 5.014;

use strict;
use warnings;

use registry 'Zing::Types';
use routines;

use Data::Object::Class;
use Data::Object::ClassHas;

extends 'Zing::Store';

# VERSION

# ATTRIBUTES

has client => (
  is => 'ro',
  isa => 'InstanceOf["DBI::db"]',
  new => 1,
);

fun new_client($self) {
  my $dbname = $ENV{ZING_DBNAME} || 'zing';
  my $dbhost = $ENV{ZING_DBHOST} || 'localhost';
  my $dbport = $ENV{ZING_DBPORT} || '3306';
  my $dbuser = $ENV{ZING_DBUSER} || 'root';
  my $dbpass = $ENV{ZING_DBPASS};
  require DBI; DBI->connect(
    join(';',
      "dbi:mysql:database=$dbname",
      $dbhost ? join('=', 'host', $dbhost) : (),
      $dbport ? join('=', 'port', $dbport) : (),
    ),
    $dbuser, $dbpass,
    {
      AutoCommit => 1,
      PrintError => 0,
      RaiseError => 1
    }
  );
}

has meta => (
  is => 'ro',
  isa => 'Str',
  new => 1,
);

fun new_meta($self) {
  require Zing::ID; Zing::ID->new->string
}

has table => (
  is => 'ro',
  isa => 'Str',
  new => 1,
);

fun new_table($self) {
  $ENV{ZING_DBZONE} || 'entities'
}

# BUILDERS

fun new_encoder($self) {
  require Zing::Encoder::Dump; Zing::Encoder::Dump->new;
}

fun BUILD($self) {
  my $client = $self->client;
  my $table = $self->table;
  local $@; eval {
    $client->do(qq{
      create table if not exists `$table` (
        `id` int not null auto_increment primary key,
        `key` varchar(255) not null,
        `value` mediumtext not null,
        `index` int default 0,
        `meta` varchar(255) null
      ) engine = innodb
    });
  }
  unless (defined(do{
    local $@;
    local $client->{RaiseError} = 0;
    local $client->{PrintError} = 0;
    eval {
      $client->do(qq{
        select 1 from `$table` where 1 = 1
      })
    }
  }));
  return $self;
}

fun DESTROY($self) {
  $self->client->disconnect;
  return $self;
}

# METHODS

my $retries = 10;

method drop(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  my $sth = $client->prepare(
    qq{delete from `$table` where `key` = ?}
  );
  $sth->execute($key);
  return $sth->rows > 0 ? 1 : 0;
}

method keys(Str $query) {
  $query =~ s/\*/%/g;
  my $table = $self->table;
  my $client = $self->client;
  my $data = $client->selectall_arrayref(
    qq{select distinct(`key`) from `$table` where `key` like ?},
    {},
    $query,
  );
  return [map $$_[0], @$data];
}

method lpull(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  for my $attempt (1..$retries) {
    local $@; eval {
      my $sth = $client->prepare(
        qq{
          update `$table` set `meta` = ? where `id` = (
            select `s1`.`id` from (
              select `s0`.`id` from `$table` `s0`
              where `s0`.`key` = ? and `s0`.`meta` is null
              order by `s0`.`index` asc limit 1
            ) as `s1`
          )
        }
      );
      $sth->execute($self->meta, $key);
    };
    if ($@) {
      die $@ if $attempt == $retries;
    }
    else {
      last;
    }
  }
  my $data = $client->selectrow_arrayref(
    qq{
      select `id`, `value`
      from `$table` where `meta` = ? and `key` = ? order by `index` asc limit 1
    },
    {},
    $self->meta, $key,
  );
  if ($data) {
    my $sth = $client->prepare(
      qq{delete from `$table` where `id` = ?}
    );
    $sth->execute($data->[0]);
  }
  return $data ? $self->decode($data->[1]) : undef;
}

method lpush(Str $key, HashRef $val) {
  my $table = $self->table;
  my $client = $self->client;
  my $sth = $client->prepare(
    qq{
      insert into `$table` (`key`, `value`, `index`) values (?, ?, (
        select ifnull(min(`s0`.`index`), 0) - 1
        from `$table` `s0` where `s0`.`key` = ?
      ))
    }
  );
  for my $attempt (1..$retries) {
    local $@; eval {
      $sth->execute($key, $self->encode($val), $key);
    };
    if ($@) {
      die $@ if $attempt == $retries;
    }
    else {
      last;
    }
  }
  return $sth->rows;
}

method read(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  my $data = $client->selectrow_arrayref(
    qq{
      select `value` from `$table`
      where `key` = ? order by `id` desc limit 1
    },
    {},
    $key,
  );
  return $data ? $data->[0] : undef;
}

method recv(Str $key) {
  my $data = $self->read($key);
  return $data ? $self->decode($data) : $data;
}

method rpull(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  for my $attempt (1..$retries) {
    local $@; eval {
      my $sth = $client->prepare(
        qq{
          update `$table` set `meta` = ? where `id` = (
            select `s1`.`id` from (
              select `s0`.`id` from `$table` `s0`
              where `s0`.`key` = ? and `s0`.`meta` is null
              order by `s0`.`index` desc limit 1
            ) as `s1`
          )
        }
      );
      $sth->execute($self->meta, $key);
    };
    if ($@) {
      die $@ if $attempt == $retries;
    }
    else {
      last;
    }
  }
  my $data = $client->selectrow_arrayref(
    qq{
      select `id`, `value`
      from `$table` where `meta` = ? and `key` = ? order by `index` desc limit 1
    },
    {},
    $self->meta, $key,
  );
  if ($data) {
    my $sth = $client->prepare(
      qq{delete from `$table` where `id` = ?}
    );
    $sth->execute($data->[0]);
  }
  return $data ? $self->decode($data->[1]) : undef;
}

method rpush(Str $key, HashRef $val) {
  my $table = $self->table;
  my $client = $self->client;
  my $sth = $client->prepare(
    qq{
      insert into `$table` (`key`, `value`, `index`) values (?, ?, (
        select ifnull(max(`s0`.`index`), 0) + 1
        from `$table` `s0` where `s0`.`key` = ?
      ))
    }
  );
  for my $attempt (1..$retries) {
    local $@; eval {
      $sth->execute($key, $self->encode($val), $key);
    };
    if ($@) {
      die $@ if $attempt == $retries;
    }
    else {
      last;
    }
  }
  return $sth->rows;
}

method send(Str $key, HashRef $val) {
  my $set = $self->encode($val);
  $self->write($key, $set);
  return 'OK';
}

method size(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  my $data = $client->selectrow_arrayref(
    qq{select count(`key`) from `$table` where `key` = ?},
    {},
    $key,
  );
  return $data->[0];
}

method slot(Str $key, Int $pos) {
  my $table = $self->table;
  my $client = $self->client;
  my $data = $client->selectrow_arrayref(
    qq{
      select `value` from `$table`
      where `key` = ? order by `index` asc limit ?, 1
    },
    {},
    $key, $pos
  );
  return $data ? $self->decode($data->[0]) : undef;
}

method test(Str $key) {
  my $table = $self->table;
  my $client = $self->client;
  my $data = $client->selectrow_arrayref(
    qq{select count(`id`) from `$table` where `key` = ?},
    {},
    $key,
  );
  return $data->[0] ? 1 : 0;
}

method write(Str $key, Str $data) {
  my $table = $self->table;
  my $client = $self->client;
  $client->prepare(
    qq{delete from `$table` where `key` = ?}
  )->execute($key);
  $client->prepare(
    qq{insert into `$table` (`key`, `value`) values (?, ?)}
  )->execute($key, $data);
  return $self;
}

1;
