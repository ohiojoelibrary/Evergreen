# MFHD::Holding provides some additional holdings logic to a MARC::Field
# object.  In its current state it is primarily read-only, as direct changes
# to the underlying MARC::Field are not reflected in the MFHD logic layer, and
# only the 'increment', 'notes', and 'seqno' methods do updates to the
# MARC::Field layer.

package MFHD::Holding;
use strict;
use integer;

use Carp;
use DateTime;
use Data::Dumper;

use base 'MARC::Field';

sub new {
    my $proto     = shift;
    my $class     = ref($proto) || $proto;
    my $seqno     = shift;
    my $self      = shift;
    my $caption   = shift;
    my $last_enum = undef;

    $self->{_mfhdh_SEQNO}          = $seqno;
    $self->{_mfhdh_CAPTION}        = $caption;
    $self->{_mfhdh_DESCR}          = {};
    $self->{_mfhdh_COPY}           = undef;
    $self->{_mfhdh_BREAK}          = undef;
    $self->{_mfhdh_NOTES}          = {};
    $self->{_mfhdh_NOTES}{public}  = [];
    $self->{_mfhdh_NOTES}{private} = [];
    $self->{_mfhdh_COPYRIGHT}      = [];
    $self->{_mfhdh_COMPRESSED}     = ($self->indicator(2) eq '0' || $self->indicator(2) eq '2') ? 1 : 0;
    # TODO: full support for second indicators 2, 3, and 4
    $self->{_mfhdh_OPEN_ENDED}     = 0;

    foreach my $subfield ($self->subfields) {
        my ($key, $val) = @$subfield;

        if ($key =~ /[a-m]/) {
            if ($self->{_mfhdh_COMPRESSED}) {
                $self->{_mfhdh_FIELDS}->{$key}{HOLDINGS} = [split(/\-/, $val)];
            } else {
                $self->{_mfhdh_FIELDS}->{$key}{HOLDINGS} = [$val];
            }
            if ($key =~ /[a-h]/) {
                # Enumeration specific details of holdings
                $self->{_mfhdh_FIELDS}->{$key}{UNIT} = undef;
                $last_enum = $key;
            }
        } elsif ($key eq 'o') {
            warn '$o specified prior to first enumeration'
              unless defined($last_enum);
            $self->{_mfhdh_FIELDS}->{$last_enum}->{UNIT} = $val;
            $last_enum = undef;
        } elsif ($key =~ /[npq]/) {
            $self->{_mfhdh_DESCR}->{$key} = $val;
        } elsif ($key eq 's') {
            push @{$self->{_mfhdh_COPYRIGHT}}, $val;
        } elsif ($key eq 't') {
            $self->{_mfhdh_COPY} = $val;
        } elsif ($key eq 'w') {
            carp "Unrecognized break indicator '$val'"
              unless $val =~ /^[gn]$/;
            $self->{_mfhdh_BREAK} = $val;
        } elsif ($key eq 'x') {
            push @{$self->{_mfhdh_NOTES}{private}}, $val;
        } elsif ($key eq 'z') {
            push @{$self->{_mfhdh_NOTES}{public}}, $val;
        }
    }

    if (   $self->{_mfhdh_COMPRESSED}
        && $self->{_mfhdh_FIELDS}{'a'}{HOLDINGS}[1] eq '') {
        $self->{_mfhdh_OPEN_ENDED} = 1;
    }
    bless($self, $class);
    return $self;
}

#
# accessor to the object's field hash
#
# We are avoiding calling these elements 'subfields' because they are more
# than simply the MARC subfields, although in the current implementation they
# are indexed on the subfield key
#
# TODO: this accessor should probably be replaced with methods which hide the
# underlying structure of {_mfhdh_FIELDS} (see field_values for a start)
#
sub fields {
    my $self = shift;

    return $self->{_mfhdh_FIELDS};
}

#
# Given a field key, returns an array ref of one (for single statements)
# or two (for compressed statements) values
#
# TODO: add setter functionality to replace direct {HOLDINGS} access in other
# methods. It also makes sense to override some of the MARC::Field setter
# methods (such as update()) to accomplish this level of encapsulation.
#
sub field_values {
    my ($self, $key) = @_;

    if (exists $self->fields->{$key}) {
        my @values = @{$self->fields->{$key}{HOLDINGS}};
        return \@values;
    } else {
        return undef;
    }
}

sub seqno {
    my $self = shift;

    if (@_) {
        $self->{_mfhdh_SEQNO} = $_[0];
        $self->update(8 => $self->caption->link_id . '.' . $_[0]);
    }

    return $self->{_mfhdh_SEQNO};
}

#
# Optionally accepts a true/false value to set the 'compressed' attribute
# Returns 'compressed' attribute
#
sub is_compressed {
    my $self = shift;
    my $is_compressed = shift;

    if (defined($is_compressed)) {
        if ($is_compressed) {
            $self->{_mfhdh_COMPRESSED} = 1;
            $self->update(ind2 => '0');
        } else {
            $self->{_mfhdh_COMPRESSED} = 0;
            $self->update(ind2 => '1');
        }
    }

    return $self->{_mfhdh_COMPRESSED};
}

sub is_open_ended {
    my $self = shift;

    return $self->{_mfhdh_OPEN_ENDED};
}

sub caption {
    my $self = shift;

    return $self->{_mfhdh_CAPTION};
}

#
# notes: If called with no arguments, returns the public notes array ref.
# If called with a single argument, it returns either 'public' or
# 'private' notes based on the passed string.
#
# If called with more than one argument, it sets the proper note field, with
# type being the first argument and the note value(s) as the remaining
# argument(s).
#
# It is also optional to pass in an array ref of note values as the third
# argument rather than a list.
#
sub notes {
    my $self  = shift;
    my $type  = shift;
    my @notes = @_;

    if (!$type) {
        $type = 'public';
    } elsif ($type ne 'public' && $type ne 'private') {
        carp("Notes being applied without specifying type");
        unshift(@notes, $type);
        $type = 'public';
    }

    if (ref($notes[0])) {
        $self->{_mfhdh_NOTES}{$type} = $notes[0];
        $self->_replace_note_subfields($type, @{$notes[0]});
    } elsif (@notes) {
        if ($notes[0]) {
            $self->{_mfhdh_NOTES}{$type} = \@notes;
        } else {
            $self->{_mfhdh_NOTES}{$type} = [];
        }
        $self->_replace_note_subfields($type, @notes);
    }

    return $self->{_mfhdh_NOTES}{$type};
}

#
# utility function for 'notes' method
#
sub _replace_note_subfields {
    my $self              = shift;
    my $type              = shift;
    my @notes             = @_;
    my %note_subfield_ids = ('public' => 'z', 'private' => 'x');

    $self->delete_subfield(code => $note_subfield_ids{$type});

    foreach my $note (@notes) {
        $self->add_subfields($note_subfield_ids{$type} => $note);
    }
}

#
# return a simple subfields list (for easier revivification from database)
#
sub subfields_list {
    my $self = shift;
    my @subfields;

    foreach my $subfield ($self->subfields) {
        push(@subfields, $subfield->[0], $subfield->[1]);
    }
    return @subfields;
}

#
# Called by method 'format_part' for formatting the chronology portion of
# the holding statement
#
sub format_chron {
    my $self     = shift;
    my $holdings = shift;
    my $caption  = $self->caption;
    my @keys     = @_;
    my $str      = '';
    my %month    = (
        '01' => 'Jan.',
        '02' => 'Feb.',
        '03' => 'Mar.',
        '04' => 'Apr.',
        '05' => 'May ',
        '06' => 'Jun.',
        '07' => 'Jul.',
        '08' => 'Aug.',
        '09' => 'Sep.',
        '10' => 'Oct.',
        '11' => 'Nov.',
        '12' => 'Dec.',
        '21' => 'Spring',
        '22' => 'Summer',
        '23' => 'Autumn',
        '24' => 'Winter'
    );

    foreach my $i (0..@keys) {
        my $key = $keys[$i];
        my $capstr;
        my $chron;
        my $sep;

        last if !defined $caption->capstr($key);

        $capstr = $caption->capstr($key);
        if (substr($capstr, 0, 1) eq '(') {
            # a caption enclosed in parentheses is not displayed
            $capstr = '';
        }

        # If this is the second level of chronology, then it's
        # likely to be a month or season, so we should use the
        # string name rather than the number given.
        if (($i == 1)) {
            # account for possible combined issue chronology
            my @chron_parts = split('/', $holdings->{$key});
            for (my $i = 0; $i < @chron_parts; $i++) {
                $chron_parts[$i] = $month{$chron_parts[$i]} if exists $month{$chron_parts[$i]};
            }
            $chron = join('/', @chron_parts);
        } else {
            $chron = $holdings->{$key};
        }

        $str .= (($i == 0 || $str =~ /[. ]$/) ? '' : ':') . $capstr . $chron;
    }

    return $str;
}

#
# Called by method 'format' for each member of a possibly compressed holding
#
sub format_part {
    my $self           = shift;
    my $holding_values = shift;
    my $caption        = $self->caption;
    my $str            = '';

    if ($caption->type_of_unit) {
        $str = $caption->type_of_unit . ' ';
    }

    if ($caption->enumeration_is_chronology) {
        # if issues are identified by chronology only, then the
        # chronology data is stored in the enumeration subfields,
        # so format those fields as if they were chronological.
        $str = $self->format_chron($holding_values, 'a'..'f');
    } else {
        # OK, there is enumeration data and maybe chronology
        # data as well, format both parts appropriately

        # Enumerations
        foreach my $key ('a'..'f') {
            my $capstr;
            my $chron;
            my $sep;

            last if !defined $caption->capstr($key);

            $capstr = $caption->capstr($key);
            if (substr($capstr, 0, 1) eq '(') {
                # a caption enclosed in parentheses is not displayed
                $capstr = '';
            }
            $str .=
              ($key eq 'a' ? '' : ':') . $capstr . $holding_values->{$key};
        }

        # Chronology
        if (defined $caption->capstr('i')) {
            $str .= '(';
            $str .= $self->format_chron($holding_values, 'i'..'l');
            $str .= ')';
        }

        if ($caption->capstr('g')) {
            # There's at least one level of alternative enumeration
            $str .= '=';
            foreach my $key ('g', 'h') {
                $str .=
                    ($key eq 'g' ? '' : ':')
                  . $caption->capstr($key)
                  . $holding_values->{$key};
            }

            # This assumes that alternative chronology is only ever
            # provided if there is an alternative enumeration.
            if ($caption->capstr('m')) {
                # Alternative Chronology
                $str .= '(';
                $str .= $caption->capstr('m') . $holding_values->{'m'};
                $str .= ')';
            }
        }
    }

    # Breaks in the sequence
    if (defined($self->{_mfhdh_BREAK})) {
        if ($self->{_mfhdh_BREAK} eq 'n') {
            $str .= ' non-gap break';
        } elsif ($self->{_mfhdh_BREAK} eq 'g') {
            $str .= ' gap';
        } else {
            warn "unrecognized break indicator '$self->{_mfhdh_BREAK}'";
        }
    }

    return $str;
}

#
# Create and return a string which conforms to display standard Z39.71
#
sub format {
    my $self      = shift;
    my $subfields = $self->fields;
    my %holding_start;
    my %holding_end;
    my $formatted;

    foreach my $key (keys %$subfields) {
        ($holding_start{$key}, $holding_end{$key}) =
          @{$self->field_values($key)};
    }

    if ($self->is_compressed) {
        # deal with open-ended statements
        my $formatted_end;
        if ($self->is_open_ended) {
            $formatted_end = '';
        } else {
            $formatted_end = $self->format_part(\%holding_end);
        }
        $formatted =
          $self->format_part(\%holding_start) . ' - ' . $formatted_end;
    } else {
        $formatted = $self->format_part(\%holding_start);
    }

    # Public Note
    if (@{$self->notes}) {
        $formatted .= ' -- ' . join(', ', @{$self->notes});
    }

    return $formatted;
}

# next: Given a holding statement, return a hash containing the
# enumeration values for the next issues, whether we hold it or not
# Just pass through to Caption::next
#
sub next {
    my $self    = shift;
    my $caption = $self->caption;

    return $caption->next($self);
}

#
# matches($pat): check to see if $self matches the enumeration hashref passed
# in as $pat, as returned by the 'next' method. e.g.:
# $holding2->matches($holding1->next) # true if $holding2 directly follows
# $holding1
#
# Always returns false if $self is compressed
#
sub matches {
    my $self = shift;
    my $pat  = shift;

    return 0 if $self->is_compressed;

    foreach my $key ('a'..'f') {
        # If a subfield exists in $self but not in $pat, or vice versa
        # or if the field has different values, then fail
        if (
            defined($self->field_values($key)) != exists($pat->{$key})
            || (exists $pat->{$key}
                && ($self->field_values($key)->[0] ne $pat->{$key}))
          ) {
            return 0;
        }
    }
    return 1;
}

#
# Check that all the fields in a holdings statement are
# included in the corresponding caption.
#
sub validate {
    my $self = shift;

    foreach my $key (keys %{$self->fields}) {
        if (!$self->caption || !$self->caption->capfield($key)) {
            return 0;
        }
    }
    return 1;
}

#
# Replace a single holding with it's next prediction
# and return itself
#
# If the holding is compressed, the range is expanded
#
sub increment {
    my $self = shift;

    if ($self->is_open_ended) {
        carp "Holding is open-ended, cannot increment";
        return $self;
    }

    my $next = $self->next();

    if ($self->is_compressed) {    # expand range
        foreach my $key (keys %{$next}) {
            my @values = @{$self->field_values($key)};
            $values[1] = $next->{$key};
            $self->fields->{$key}{HOLDINGS} = \@values;
            $next->{$key} = join('-', @values);
        }
    } else {
        foreach my $key (keys %{$next}) {
            $self->fields->{$key}{HOLDINGS}[0] = $next->{$key};
        }
    }

    $self->seqno($self->seqno + 1);
    $self->update(%{$next});    # update underlying subfields
    return $self;
}

#
# Turns a compressed holding into the singular form of the last member
# in the range
#
sub compressed_to_last {
    my $self = shift;

    if (!$self->is_compressed) {
        carp "Holding not compressed, cannot convert to last member";
        return $self;
    } elsif ($self->is_open_ended) {
        carp "Holding is open-ended, cannot convert to last member";
        return $self;
    }

    my %changes;
    foreach my $key (keys %{$self->fields}) {
        my @values = @{$self->field_values($key)};
        $self->fields->{$key}{HOLDINGS} = [$values[1]];
        $changes{$key} = $values[1];
    }

    $self->update(%changes);    # update underlying subfields
    $self->is_compressed(0);    # remove compressed state

    return $self;
}

#
# Basic, working, unoptimized clone operation
#
sub clone {
    my $self = shift;

    my $clone_field = $self->SUPER::clone();
    return new MFHD::Holding($self->seqno, $clone_field, $self->caption);
}

#
# Turn a chronology instance into date(s) in YYYY-MM-DD format
#
# In list context it returns a list of start and (possibly undefined)
# end dates
#
# In scalar context, it returns a YYYY-MM-DD date string of either the
# single date or the (possibly undefined) end date of a compressed holding
#
sub chron_to_date {
    my $self    = shift;
    my $caption = $self->caption;

    my @keys;
    if ($caption->enumeration_is_chronology) {
        @keys = ('a'..'f');
    } else {
        @keys = ('i'..'m');
    }

    # @chron_start and @chron_end will hold the (year, month, day) values
    # represented by the start and optional end of the chronology instance.
    # Default to January 1 with a year of 0 as initial values.
    my @chron_start = (0, 1, 1);
    my @chron_end   = (0, 1, 1);
    my @chrons = (\@chron_start, \@chron_end);
    foreach my $key (@keys) {
        my $capstr = $caption->capstr($key);
        last if !defined($capstr);
        if ($capstr =~ /year/) {
            ($chron_start[0], $chron_end[0]) = @{$self->field_values($key)};
        } elsif ($capstr =~ /month/) {
            ($chron_start[1], $chron_end[1]) = @{$self->field_values($key)};
        } elsif ($capstr =~ /day/) {
            ($chron_start[2], $chron_end[2]) = @{$self->field_values($key)};
        } elsif ($capstr =~ /season/) {
            # chrons defined as season-only will use the astronomical season
            # dates as a basic estimate.
            my @seasons = @{$self->field_values($key)};
            for (my $i = 0; $i < @seasons; $i++) {
                $seasons[$i] = &_uncombine($seasons[$i], 0);
                if ($seasons[$i] == 21) {
                    $chrons[$i]->[1] = 3;
                    $chrons[$i]->[2] = 20;
                } elsif ($seasons[$i] == 22) {
                    $chrons[$i]->[1] = 6;
                    $chrons[$i]->[2] = 21;
                } elsif ($seasons[$i] == 23) {
                    $chrons[$i]->[1] = 9;
                    $chrons[$i]->[2] = 22;
                } elsif ($seasons[$i] == 24) {
                    $chrons[$i]->[1] = 12;
                    $chrons[$i]->[2] = 21;
                }
            }
        }
    }

    my @dates;
    foreach my $chron (@chrons) {
        my $date = undef;
        if ($chron->[0] != 0) {
            $date =
                &_uncombine($chron->[0], 0) . '-'
              . sprintf('%02d', $chron->[1]) . '-'
              . sprintf('%02d', $chron->[2]);
        }
        push(@dates, $date);
    }

    if (wantarray()) {
        return @dates;
    } elsif ($self->is_compressed) {
        return $dates[1];
    } else {
        return $dates[0];
    }
}

#
# utility function for uncombining instance parts
#
sub _uncombine {
    my ($combo, $pos) = @_;

    if (ref($combo)) {
        carp("Function '_uncombine' is not an instance method");
        return;
    }

    my @parts = split('/', $combo);
    return $parts[$pos];
}
1;
