#!/usr/bin/perl -w

=head1 NAME

GFFTree

=head1 SYNOPSIS

  my $gff = GFFTree->new({});
  $gff->name('GFF');
  $gff->parse_file();
  $gff->add_expectation('mrna','hasParent','gene','find');
  $gff->add_expectation('mrna','<[_start,_end]','SELF','warn');
  $gff->add_expectation('mrna','>=[_start]','PARENT','warn');
  while (my $gene = $gff->next_feature('gene')){
	while (my $mrna = $gene->next_feature('mrna')){
		$mrna->validate;
	}
  }


=head1 DESCRIPTION

This module is intended to be as close as possible to a universal gff3 file parser. 

Calling parse_file causes the gff3 file to be read into a graph structure, allowing 
relationships to be queried and modified during an optional validation step, which can be 
applied to individual features independently.

The parser makes no assumptions about the feature types expected in column 3 nor the 
content of column 9 (other than that it is a set of key-value pairs).  Expected properties 
of, and relationships among and between, features may be defined as a set of expectations, 
which can be tested during an optional validation step. The behaviour of the parser on 
finding an unmet assumption (to ignore, warn, die, link to an existing feature or create a 
new feature) can be defined independently for each assumption through the use of flags.

=cut

use strict;
package GFFTree;
use Tree::DAG_Node;
our @ISA=qw(Tree::DAG_Node);
use Encode::Escape::ASCII;

=head2 new
  Function : Creates a new GFFTree
  Example  : $gff = GFFTree->new({});
=cut

sub new {
    my $class = shift;
    my $options = shift;
    my $self = bless $class->SUPER::new();
    $self->attributes($options);
    return $self;
}


# use nesting to allow subs to share and retain access to private variables
{
	my %ids;
	my %by_start;
	my %type_map;
	my %multiline;

=head2 map_types
  Function : Loads a mapping of types to allow treating of features with different types 
             as one
  Example  : $gff->map_types({'internal' => 'exon'});
=cut

	sub map_types {
		my $mapping = pop;
	    foreach my $type (keys %{$mapping}){
	    	$type_map{$type} = $mapping->{$type};
	    }
	    return scalar keys %type_map;
	}


=head2 multiline
  Function : Specify feature types that can be split over multiple lines use 'all' to 
  allow any feature be multiline 
  Example  : $gff->multiline('cds');
=cut

	sub multiline {
		my $types = pop;
		$types =~ tr/[A-Z]/[a-z]/;
		my @types = split /\|/,$types;
	    while (my $type = shift @types){
	    	$multiline{$type} = 1;
	    }
	    return scalar keys %multiline;
	}


=head2 is_multiline
  Function : Test whether feature type can be split ove multiple lines
  Example  : $gff->is_multiline('cds');
=cut

	sub is_multiline {
		return 1 if $multiline{'all'};
		my $type = pop;
		$type =~ tr/[A-Z]/[a-z]/;
		return 1 if $multiline{$type};
	}


=head2 parse_file
  Function : Reads a gff3 file into a tree structure, handling multiline features and 
             ordering features on the same region
  Example  : $gff->parse_file();
=cut

	sub parse_file {
		my $node = shift;
		my $fasta;
		my $region;
		my $seq = '';
	    while (<>){
			chomp $_;
			if (my $ret = is_comment($_)){
				if ($ret == -9){
					$fasta = substr $_,1;
				}
				else {
					$fasta = undef;
					$seq = '';
					$region = undef;
				}
				next;
			}
			elsif ($fasta){
				$seq .= $_;
				$region = $node->by_attributes(['_type','region'],['_seq_name',$fasta]) unless $region;
				unless ($region){
					$region = $node->make_region($fasta,'region');
				}
				$region->{attributes}->{_seq} = $seq;
				$region->{attributes}->{_end} = length $seq;
				next;
			}
			my $parent = $node;
			my ($data,$attribs) = parse_gff_line($_);
			my %attributes;
			$attributes{'_seq_name'} = $data->[0];
			$attributes{'_source'} = $data->[1];
			$attributes{'_type'} = $type_map{$data->[2]} ? $type_map{$data->[2]} : $data->[2];
			$attributes{'_start'} = $data->[3];
			$attributes{'_end'} = $data->[4];
			$attributes{'_score'} = $data->[5];
			$attributes{'_strand'} = $data->[6];
			$attributes{'_phase'} = $data->[7];
			if ($attribs->{'Parent'}){
				$parent = $ids{$attribs->{'Parent'}};
			}
			else {
				# check type to decide what to do with features without parents
			}
			
			if (!$attribs->{'ID'}){ # need to do something about features that lack IDs
				my $behaviour = $node->lacks_id();
				next if $behaviour eq 'ignore';
				if ($behaviour eq 'warn'){
					warn "WARNING: the feature on line $. does not have an ID, skipping feature\n";
					next;
				}
				elsif ($behaviour eq 'die'){
					die "ERROR: the feature on line $. does not have an ID, cannot continue\n";
				}
				else {
					my $prefix = $attributes{'_type'}.'___';
					my $suffix = 0;
					while (by_id($prefix.$suffix)){
						$suffix++;
					}
					$attribs->{'ID'} = $prefix.$suffix;
				}
			}
			
			$attribs->{'ID'} =~ s/'//g;
				
			if (ref $attribs->{'Parent'} eq 'ARRAY'){ # multiparent feature
				my $base_id = $attribs->{'ID'};
				delete $attribs->{'ID'};
				my @parents = @{$attribs->{'Parent'}};
				#delete $attribs->{'Parent'};
				for (my $p = 0; $p < @parents; $p++){
					#$attributes{'Parent'} = $parents[$p];
					my $id;
					if ($p == 0){
						$attributes{'_duplicate'} = 0;
						$id = $base_id;
					}
					else {
						$attributes{'_duplicate'} = 1;
						$id = $base_id.'._'.$p;
					}
					$id = $p == 0 ? $base_id : $base_id.'._'.$p;
					$attributes{'ID'} = $id;
					$ids{$id} = $ids{$parents[$p]}->new_daughter({%attributes,%$attribs});
					$ids{$id}->name($id);
					push @{$by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$attributes{'_start'}}},$id;
				}
			}
			elsif (my $existing = $ids{$attribs->{'ID'}}){ # test if ID already exists, then treat as clash or multline
				if (is_multiline($attributes{'_type'}) &&
					$existing->{attributes}->{'_seq_name'} eq $attributes{'_seq_name'} &&
					$existing->{attributes}->{'_type'} eq $attributes{'_type'} &&
					$existing->{attributes}->{'_strand'} eq $attributes{'_strand'} &&
					$attribs->{'Parent'} &&
					$existing->{attributes}->{'Parent'} eq $attribs->{'Parent'}
					){
					# change _start and _end, storing individual component values in an array
					push @{$existing->{attributes}->{'_start_array'}},$existing->{attributes}->{'_start'} unless $existing->{attributes}->{'_start_array'};
					push @{$existing->{attributes}->{'_end_array'}},$existing->{attributes}->{'_end'} unless $existing->{attributes}->{'_end_array'};
					push @{$existing->{attributes}->{'_phase_array'}},$existing->{attributes}->{'_phase'} unless $existing->{attributes}->{'_phase_array'};
					if ($attributes{'_start'} > $existing->{attributes}->{'_start'}){
						push @{$existing->{attributes}->{'_start_array'}},$attributes{'_start'};
						push @{$existing->{attributes}->{'_end_array'}},$attributes{'_end'};
						push @{$existing->{attributes}->{'_phase_array'}},$attributes{'_phase'};
						$existing->{attributes}->{'_end'} = $attributes{'_end'};
					}
					else {
						unshift @{$existing->{attributes}->{'_start_array'}},$attributes{'_start'};
						unshift @{$existing->{attributes}->{'_end_array'}},$attributes{'_end'};
						unshift @{$existing->{attributes}->{'_phase_array'}},$attributes{'_phase'};
						for (my $s = 0; $s < @{$by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$existing->{attributes}->{'_start'}}}; $s++){
							my $possible = $by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$existing->{attributes}->{'_start'}}[$s];
							if ($possible eq $existing){
								# remove and replace
								splice(@{$by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$existing->{attributes}->{'_start'}}}, $s, 1);
								$existing->{attributes}->{'_start'} = $attributes{'_start'};
								push @{$by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$attributes{'_start'}}},$existing;
								last;
							}
						}
						#
						
					}
				}
				else {
					# ID clash
				}
			}
			else {
				$ids{$attribs->{'ID'}} = $parent->new_daughter({%attributes,%$attribs});
				$ids{$attribs->{'ID'}}->name($attribs->{'ID'});
				push @{$by_start{$attributes{'_seq_name'}}{$attributes{'_type'}}{$attributes{'_start'}}},$ids{$attribs->{'ID'}};
			}
		}
		return 1;
	}

=head2 by_id
  Function : Fetch a node by unique id
  Example  : $node = by_id('id');
=cut

	sub by_id  {
		my $id = pop;
		return $ids{$id};
	}

=head2 make_id
  Function : generate a unique id for a node
  Example  : $id = $node->make_id('prefix');
=cut

	sub make_id  {
		my $node = shift;
		my $prefix = shift;
		my $suffix = shift;
		$suffix = 0 unless $suffix;
		while (by_id($prefix.$suffix)){
			$suffix++;
		}
		my $id = $prefix.$suffix;
		$node->name($id);
		$node->{attributes}->{'ID'} = $id;
		$ids{$id} = $node;
		push @{$by_start{$node->{attributes}->{_seq_name}}{$node->{attributes}->{_type}}{$node->{attributes}->{_start}}},$node;
		return $id;
	}

	
=head2 by_start
  Function : Fetch an arrayref of nodes start position
  Example  : $node_arrayref = by_start('scaf1','exon',432);
=cut

	sub by_start  {
		my $start = pop;
		my $type = pop;
		my $seq_name = pop;
		return $by_start{$seq_name}{$type}{$start};
	}

=head2 nearest_start
  Function : Fetch an arrayref of nodes as close as possible to the start position
  Example  : $node_arrayref = nearest_start('scaf1','exon',432);
=cut

	sub nearest_start  {
		my $start = pop;
		my $type = pop;
		my $seq_name = pop;
		my $prev_begin = 0;
		foreach my $begin (sort { $a <=> $b } keys %{$by_start{$seq_name}{$type}}){
			last if $begin > $start;
			$prev_begin = $begin;
		}	
		return $by_start{$seq_name}{$type}{$prev_begin};
	}

}

=head2 lacks_id
  Function : get/set behaviour for features that lack an id
  Example  : $gff->lacks_id('ignore');
  Example  : $gff->lacks_id('warn');
  Example  : $gff->lacks_id('die');
  Example  : $gff->lacks_id('make'); # default
  Example  : $behaviour = $gff->lacks_id();
=cut

sub lacks_id  {
	my $node = shift;
	my $behaviour = shift;
	$node->{_attributes}->{'_lacks_id'} = $behaviour if $behaviour;
	return $node->{_attributes}->{'_lacks_id'} ? $node->{_attributes}->{'_lacks_id'} : 'make';
}


# use nesting to allow sub to retain access to private variables

{
	my %features;
	my %parents;
	
=head2 next_feature
  Function : Sequentially fetch daughter features of a node by type
  Example  : $gene->next_feature('exon');
=cut

	sub next_feature {
		my ($self, $type) = @_;
		unless ($features{$type} && @{$features{$type}} && $parents{$type} && $parents{$type} eq $self->name){
			$self->order_features($type);
		}
		return shift @{$features{$type}};
	}
	
=head2 order_features
  Function : order daughter features of a given  type sequentially
  Example  : $gene->order_feature('exon');
=cut

	sub order_features {
		my ($self, $type, $strand) = @_;
		my @unsorted = by_type($self,$type);
		@{$features{$type}} = ($strand && $strand eq '-') ? sort { $b->{attributes}->{_start} <=> $a->{attributes}->{_start} } @unsorted : sort { $a->{attributes}->{_start} <=> $b->{attributes}->{_start} } @unsorted;
		push @{$features{$type}},0;
		$parents{$type} = $self->name;
		return (scalar(@{$features{$type}})-1);
	}
	
=head2 fill_gaps
  Function : fill in gaps between features, eg make introns based on exons, should check 
  whether such features exist before running this (maybe need a fill_gaps_unless sub)
  Example  : $gene->fill_gaps('exon','intron','internal');
             $gene->fill_gaps('exon','utr','external');
             $gene->fill_gaps('exon','5utr','before');
             $gene->fill_gaps('exon','3utr','after');
=cut

	sub fill_gaps {
		my ($self, $type, $new_type, $location) = @_;
		$self->order_features($type);
		my %attributes;
		$attributes{'_seq_name'} = $self->{attributes}->{_seq_name};
		$attributes{'_source'} = 'GFFTree';
		$attributes{'_type'} = $new_type;
		$attributes{'_score'} = '.';
		$attributes{'_strand'} = $self->{attributes}->{_strand};
		$attributes{'_phase'} = '.';
		$attributes{'Parent'} = $self->name;
		if ($location eq 'internal'){
			if (@{$features{$type}} > 2){
				for (my $i = 1; $i < @{$features{$type}} - 1; $i++){
					$attributes{'_start'} = $features{$type}[($i-1)]->{attributes}->{_end} + 1;
					$attributes{'_end'} = $features{$type}[$i]->{attributes}->{_start} - 1;
					next if $attributes{'_end'} <= $attributes{'_start'};
					if (my $feature = $self->find_daughter(\%attributes)){
						$self->add_daughter($feature);
					}
					else {
						my $node = $self->new_daughter(\%attributes);
						$node->make_id($new_type);
					}
				}
			}
		}
		if ($features{$type} > 1){
			if ($location eq 'before' || $location eq 'external'){
				if ($features{$type}[0]->{attributes}->{_end} < $self->{attributes}->{_end}){
					if ($features{$type}[0]->{attributes}->{_strand} eq '-'){
						$attributes{'_start'} = $features{$type}[0]->{attributes}->{_end} + 1;
						$attributes{'_end'} = $self->{attributes}->{_end};
					}
					else {
						$attributes{'_start'} = $self->{attributes}->{_start};
						$attributes{'_end'} = $features{$type}[0]->{attributes}->{_start} - 1;
					}
					return if $attributes{'_end'} <= $attributes{'_start'};
					if (my $feature = $self->find_daughter(\%attributes)){
						$self->add_daughter($feature);
					}
					else {
						my $node = $self->new_daughter(\%attributes);
						$node->make_id($new_type);
					}
				}
			}
			if ($location eq 'after' || $location eq 'external'){
				if ($features{$type}[-2]->{attributes}->{_end} < $self->{attributes}->{_end}){
					if ($features{$type}[0]->{attributes}->{_strand} eq '-'){
						$attributes{'_end'} = $features{$type}[-2]->{attributes}->{_start} - 1;
						$attributes{'_start'} = $self->{attributes}->{_start};
					}
					else {
						$attributes{'_end'} = $self->{attributes}->{_end};
						$attributes{'_start'} = $features{$type}[-2]->{attributes}->{_end} + 1;
					}
					return if $attributes{'_end'} <= $attributes{'_start'};
					if (my $feature = $self->find_daughter(\%attributes)){
						$self->add_daughter($feature);
					}
					else {
						my $node = $self->new_daughter(\%attributes);
						$node->make_id($new_type);
					}
				}
			}
		}
	}

=head2 find_daughter
  Function : Find out whether an element already has a daughter with a given set of 
             attributes
  Example  : $gene->find_daughter(\%attributes);
=cut

	sub find_daughter {
		my $self = shift;
		my $attributes = shift;
		my @possibles = by_start($attributes->{'_seq_name'},$attributes->{'_type'},$attributes->{'_start'});
		while (my $feature = shift @possibles){
			if ($attributes->{'_end'} == $feature->[0]->{attributes}->{'_end'}){
				return $feature->[0];
			}
		}
	}

}


# use nesting to allow subs to share and retain access to private variables
{
	my %expectations;
	# lookup table for flags
	my %actions = ( 'ignore' => \&validation_ignore,
					'warn' => \&validation_warning,
					'die' => \&validation_die,
					'find' => \&validation_find,
					'make' => \&validation_make,
					'force' => \&validation_force,
              );
	
=head2 add_expectation
  Function : Specify conditions that feature-types should meet in order to pass validation 
             expectations can be applied to multiple feature types using the pipe symbol in 
             $Arg[0]. More documentation to be written...
  Example  : $gff->add_expectation('mrna','hasParent','gene','find');
=cut

	sub add_expectation {
		# define expectations for gff validation
		# feature_type,relation,alt_type,flag
		# flags: ignore, warn, die, find, make, force
		# relations: hasParent, hasChild, >, gt, <, lt, ==, eq, >=, <=, !=, ne 
		# mrna hasParent gene 
		# mrna|exon <[start,end] SELF
		# mrna <=[end] PARENT warn
		# exon hasParent mrna|transcript|gene
		# cds hasParent exon
		
		my ($self,$type,$relation,$alt_type,$flag) = @_;
		$type =~ tr/[A-Z]/[a-z]/;
		my @type = split /\|/,$type;
		for (my $t = 0; $t < @type; $t++){
			push @{$expectations{$type[$t]}},{'relation' => $relation, 'alt_type' => $alt_type, 'flag' => $flag} || return;
		}
		return scalar keys %expectations;
	}

=head2 validate
  Function : Test whether a feature meets the conditions defined in any relevant added 
             expectations and respond according to the specified flag
  Example  : $mrna->validate();
=cut
	
	sub validate {
		my $self = shift;
		my $type = $self->{attributes}->{_type};
		$type =~ tr/[A-Z]/[a-z]/;
		if ($expectations{$type}){
			for (my $i = 0; $i < @{$expectations{$type}}; $i++){
				my $hashref = $expectations{$type}[$i];
				if ($hashref->{'relation'} eq 'hasParent'){
					my $message = $type." ".$self->name.' does not have a parent of type '.$hashref->{'alt_type'};
					$actions{$hashref->{'flag'}}->($self,$message,$expectations{$type}[$i]) unless $self->mother->{attributes}->{_type} && $self->mother->{attributes}->{_type} =~ m/$hashref->{'alt_type'}/i;
				}
				elsif ($hashref->{'relation'} eq 'hasChild'){
					#;
				}
				else {
					my @relation = split /[\[\]]/,$hashref->{'relation'};
					my @attrib = split /,/,$relation[1];
					my $message = $type.' '.$self->name.'->('.$attrib[0].') is not '.$relation[0].' '.$hashref->{'alt_type'}.'->('.$attrib[-1].')';
					my $first = $self->{attributes}->{$attrib[0]};
					my $second = $hashref->{'alt_type'} =~ m/self/i ? $self->{attributes}->{$attrib[-1]} : $self->mother->{attributes}->{$attrib[-1]};
					$actions{$hashref->{'flag'}}->($message) unless compare($first,$second,$relation[0]);
				}
			}
		}
	}
		
	sub validation_ignore {
		# nothing happens
	}
	
	sub validation_warning {
		my $message = pop;
		warn "WARNING: $message\n";
	}
	
	sub validation_die {
		my $message = pop;
		die "ERROR: $message\n";
	}

=head2 validation_find
  Function : find a feature to satisfy an expectation - limited functionality at present
  Example  : validation_find($expectation_hashref);
=cut
	
	sub validation_find {
		# TODO 	- handle relationships other than parent
		my $self = shift;
		my $expectation = pop;
		my %attributes;
		$attributes{'_seq_name'} = $self->{attributes}->{_seq_name};
		$attributes{'_source'} = 'GFFTree';
		$attributes{'_type'} = $expectation->{'alt_type'};
		$attributes{'_score'} = '.';
		$attributes{'_strand'} = $self->{attributes}->{_strand};
		$attributes{'_phase'} = '.';
		
		my $relative;	
		if ($expectation->{'relation'} eq 'hasParent'){
			my @possibles = by_start($self->{attributes}->{'_seq_name'},$expectation->{'alt_type'},$self->{attributes}->{'_start'});
			while ($relative = shift @possibles){
				if ($self->{attributes}->{'_end'} == $relative->[0]->{attributes}->{'_end'}){
					last;
				}
			}
			unless ($relative){
				@possibles = nearest_start($self->{attributes}->{'_seq_name'},$expectation->{'alt_type'},$self->{attributes}->{'_start'}) unless @possibles;
				while ($relative = shift @possibles){
					if ($self->{attributes}->{'_end'} <= $relative->[0]->{attributes}->{'_end'}){
						last;
					}
				}
			}
			if ($relative){
				my $parent = $relative->[0];
				$attributes{'_start'} = $parent->{attributes}->{_start};
				$attributes{'_end'} = $parent->{attributes}->{_end};
				$self->{attributes}->{Parent} = $parent->name();
				$self->unlink_from_mother();
				$parent->add_daughter($self);
			}
			
		}
		return $relative->[0];
	}

=head2 validation_make
  Function : make a feature to satisfy an expectation - limited to parents at the moment
  Example  : validation_make($expectation_hashref);
=cut
	
	sub validation_make {
		my $self = shift;
		my $expectation = pop;
		my %attributes;
		$attributes{'_seq_name'} = $self->{attributes}->{_seq_name};
		$attributes{'_source'} = 'GFFTree';
		$attributes{'_type'} = $expectation->{'alt_type'};
		$attributes{'_score'} = '.';
		$attributes{'_strand'} = $self->{attributes}->{_strand};
		$attributes{'_phase'} = '.';
		if ($expectation->{'relation'} eq 'hasParent'){
			if ($expectation->{'alt_type'} eq 'region'){
				# find limits of the region
				my @features = by_attribute($self,'_seq_name',$self->{attributes}->{_seq_name});
				# assuming regions always start at 1, comment out the code below if not true
				# my @sorted = sort { $a->{attributes}->{_start} <=> $b->{attributes}->{_start} } @features;
				$attributes{'_start'} = 1; # $sorted[0]->{attributes}->{_start};
				my @sorted = sort { $b->{attributes}->{_end} <=> $a->{attributes}->{_end} } @features;
				# TODO - if a sequence is available, use that to find the length of a region
				$attributes{'_end'} = $sorted[0]->{attributes}->{_end};
				$attributes{'_strand'} = '+';
			}
			else {
				$attributes{'_start'} = $self->{attributes}->{_start};
				$attributes{'_end'} = $self->{attributes}->{_end};
			}
		}
		$attributes{'Parent'} = $self->{attributes}->{Parent} if $self->{attributes}->{Parent};
		my $node = $self->mother->new_daughter(\%attributes);
		$node->make_id($expectation->{'alt_type'});
		$self->{attributes}->{Parent} = $node->name();
		$self->unlink_from_mother();
		$node->add_daughter($self);
		return $node;
	}
	
=head2 validation_force
  Function : find a feature to satisfy an expectation if possible, otherwise make one
  Example  : validation_force($expectation_hashref);
=cut

	sub validation_force {
		my $self = shift;
		my $expectation = pop;
		my $relative = $self->validation_find($expectation);
		return $relative if $relative;
		$relative = $self->validation_make($expectation);
		return $relative;
	}

}

=head2 compare
  Function : compare two values based on a specified operator
  Example  : compare(10,20,'<'); # returns true
=cut
	
sub compare {
	my ($first,$second,$operator) = @_;
	return $first > $second if $operator eq '>';
	return $first gt $second if $operator eq 'gt';
	return $first < $second if $operator eq '<';
	return $first lt $second if $operator eq 'lt';
	return $first == $second if $operator eq '==';
	return $first eq $second if $operator eq 'eq';
	return $first >= $second if $operator eq '>=';
	return $first <= $second if $operator eq '<=';
	return $first != $second if $operator eq '!=';
	return $first ne $second if $operator eq 'ne';
}


=head2 make_region
  Function : make a feature required during parsing, maybe combine with validation_make?
  Example  : parse_make($expectation_hashref);
=cut
	
sub make_region {
	my $self = shift;
	my $name = shift;
	my $type = shift;
	my %attributes;
	$attributes{'_seq_name'} = $name;
	$attributes{'_source'} = 'GFFTree';
	$attributes{'_type'} = $type;
	$attributes{'_score'} = '.';
	$attributes{'_strand'} = '+';
	$attributes{'_phase'} = '.';
	$attributes{'_start'} = 1;
	my $node = $self->new_daughter(\%attributes);
	$node->make_id($type);
	return $node;
}


=head2 as_string
  Function : returns a gff representation of a single feature
  Example  : $gene->as_string();
  Example  : $gene->as_string(1); # skip features labeled as duplicates
=cut

sub as_string {
	my $self = shift;
	my $skip_dups = shift;
	my $line = '';
	my $col_nine;
	foreach my $key (sort keys %{$self->{attributes}}){
		next if $key =~ m/^_/;
		if (ref $self->{attributes}->{$key} eq 'ARRAY') {
  			$col_nine .= $key.'='.join(',',@{$self->{attributes}->{$key}}).';'; 
		}
		else {
			my $value = $self->{attributes}->{$key};
			$value =~ s/\._\d+$//;
			$col_nine .= $key.'='.$value.';'; 
		}
	}
	chop $col_nine;
	my @start_array = ($self->{attributes}->{_start});
	my @end_array = ($self->{attributes}->{_end});
	my @phase_array = ($self->{attributes}->{_phase});
	if (is_multiline($self->{attributes}->{_type}) && $self->{attributes}->{_start_array}){
		for (my $s = 0; $s < @{$self->{attributes}->{_start_array}}; $s++){
			$start_array[$s] = $self->{attributes}->{_start_array}[$s];
			$end_array[$s] = $self->{attributes}->{_end_array}[$s];
			$phase_array[$s] = $self->{attributes}->{_phase_array}[$s];
		}
	}
	for (my $s = 0; $s < @start_array; $s++){
		next if $skip_dups && $self->{attributes}->{_duplicate};
		$line .= $self->{attributes}->{_seq_name}."\t";
		$line .= $self->{attributes}->{_source}."\t";
		$line .= $self->{attributes}->{_type}."\t";
		$line .= $start_array[$s]."\t";
		$line .= $end_array[$s]."\t";
		$line .= $self->{attributes}->{_score}."\t";
		$line .= $self->{attributes}->{_strand}."\t";
		$line .= $phase_array[$s]."\t";
		$line .= $col_nine."\n";
	}
	return $line;
}



=head2 is_comment
  Function : returns true if a line is a comment
  Example  : is_comment($line);
=cut

sub is_comment {
	return -1 if $_ =~ m/^$/;
	return -9 if $_ =~ m/^>/;
	return length($1) if $_ =~ m/^(#+)/;
}

=head2 parse_gff_line
  Function : splits a line of gff into 8 fields and a key-value hash, escaping encoded 
             characters
  Example  : parse_gff_line($line);
=cut

=head2 parse_gff_line
  Function : splits a line of gff into 8 fields and a key-value hash, escaping encoded 
             characters and building arrays of comma-separated values
  Example  : parse_gff_line($line);
=cut

sub parse_gff_line {
	my @data = split /\t/,$_;
	chomp $data[8];
	my %attribs = split /[=;]/,$data[8];
	pop @data;
	foreach my $key (keys %attribs){
		# treat differently if commas are present
		my @parts = split /,/,$attribs{$key};
		if ($parts[1]){
			$attribs{$key} = [];
			while (my $part = shift @parts){
				$part =~ s/\%/\\x/g;
				$part = decode 'ascii-escape', $part;
				push @{$attribs{$key}},$part;
			}
		}
		else {
			$attribs{$key} =~ s/\%/\\x/g;
			$attribs{$key} = decode 'ascii-escape', $attribs{$key};
		}
	}
	return \@data,\%attribs;
}


=head2 _seq_name
  Function : get/set the sequence name for a feature
  Example  : $name = $node->_seq_name();
             $node->_seq_name('new_name');
=cut

sub _seq_name {
    my $node = shift;
    my $val = shift;
    $node->attributes->{_seq_name} = $val if $val;
    return $node->attributes->{_seq_name};
}

=head2 _length
  Function : get the length of a feature
  Example  : $length = $node->_length();
=cut

sub _length {
    my $node = shift;
    my $length = $node->attributes->{_end} - $node->attributes->{_start} + 1;
    return $length;
}

=head2 _phase
  Function : get/set the phase name for a feature
  Example  : $phase = $node->_phase();
             $node->_phase(2);
=cut

sub _phase {
    my $node = shift;
    my $val = shift;
    $node->attributes->{_phase} = $val if defined $val && length $val > 0;
    return $node->attributes->{_phase};
}

=head2 _end_phase
  Function : get/set the end_phase name for a feature - ensembl specific at the moment
  Example  : $phase = $node->_end_phase();
             $node->_end_phase(2);
=cut

sub _end_phase {
    my $node = shift;
    my $val = shift;
    $node->attributes->{_end_phase} = $val if defined $val && length $val > 0;
    unless (defined $node->attributes->{_end_phase}){
    	if ($node->_phase eq '-1'){
    		$node->attributes->{_end_phase} = '-1';
    	}
    	else {
	    	$node->attributes->{_end_phase} = $node->_phase + $node->_length % 3;
    		$node->attributes->{_end_phase} -= 3 if $node->attributes->{_end_phase} > 2;
    	}
    }
    return $node->attributes->{_end_phase};
}

=head2 by_name
  Function : walk through the tree to find a feature by name, works in scalar or array 
             context
  Example  : $node = $gff->by_name('id2');
=cut


sub by_name {
    my ($self, $name) = @_;
    my @found =();
    my $retvalue = wantarray ? 1 : 0;
    $self->walk_down({callback=>sub{
        if ($_[0]->name eq $name) {
            push @found, $_[0];
            return $retvalue;
        }
        1}});
    return wantarray? @found : @found ? $found[0] : undef;
}

=head2 by_type
  Function : calls by_attribute to find an array of features of a given type
  Example  : @nodes = $gff->by_type('exon');
=cut


sub by_type {
    my ($self, $type) = @_;
    return by_attribute($self,'_type',$type);
}

=head2 by_attribute
  Function : returns a scalar or array of features with a given attribute or where an 
             attribute matches a specific value
  Example  : @nodes = $gff->by_attribute('anything');
  			 $node = $gff->by_attribute('anything','something');
=cut

sub by_attribute {
    my ($self, $attrib, $value) = @_;
    my @found =();
    my $retvalue = wantarray ? 1 : 0;
    $self->walk_down({callback=>sub{
        if ($_[0]->attributes->{$attrib}){
        	my $match  = 0;
        	if (!defined $value) {
        		$match++;
            }
            elsif (ref $_[0]->attributes->{$attrib} eq 'ARRAY'){
            	for (my $i = 0; $i < @{$_[0]->attributes->{$attrib}}; $i++){
            		if ($_[0]->attributes->{$attrib}->[$i] =~ m/^$value$/i){
        				$match++;
            		}
            	}
            }
            elsif ($_[0]->attributes->{$attrib} =~ m/^$value$/i){
            	$match++;
            }
            if ($match > 0){
            	push @found, $_[0];
            	return $retvalue;
            }
        }
        1}});
    return wantarray? @found : @found ? $found[0] : undef;
}


=head2 by_attributes
  Function : returns a scalar or array of features with each of a given set of attributes 
             or where each of a set of attributes match specific values
  Example  : @nodes = $gff->by_attributes(['anything','anything_else]);
  			 $node = $gff->by_attribute(['anything','something'],['anythingelse','somethingelse']);
=cut

sub by_attributes {
    my $self = shift;
    my @matches;
    while (my $arrayref = shift){
    	my @nodes;
    	if ($arrayref->[1]){
    		@nodes = $self->by_attribute($arrayref->[0],$arrayref->[1]);
    	}
    	else {
    		@nodes = $self->by_attribute($arrayref->[0]);
    	}
    	if (@matches){
    		my @tmp;
    		for (my $i = 0; $i < @matches; $i++){
    			for (my $j = 0; $j < @nodes; $j++){
    				push @tmp,$matches[$i] if $matches[$i] == $nodes[$j];
    			}
    		}
    		@matches = @tmp;
    	}
    	else {
    		@matches = @nodes;
    	}
    	return undef unless @matches;
    }
    return wantarray? @matches : $matches[0];
}


=head2 by_not_attribute
  Function : returns a scalar or array of features without a given attribute or where an 
             attribute does not match a specific value
  Example  : @nodes = $gff->by_attribute('anything');
  			 @nodes = $gff->by_attribute('anything','something');
=cut

sub by_not_attribute {
    my ($self, $attrib, $value) = @_;
    my @found =();
    my $retvalue = wantarray ? 1 : 0;
    $self->walk_down({callback=>sub{
    	my $match  = 0;
    	if ($_[0]->attributes->{$attrib}){
    		if (defined $value){
    			if (ref $_[0]->attributes->{$attrib} eq 'ARRAY'){
    				for (my $i = 0; $i < @{$_[0]->attributes->{$attrib}}; $i++){
            			if ($_[0]->attributes->{$attrib}->[$i] =~ m/^$value$/i){
        					$match++;
            			}
            		}
    			}
    			elsif ($_[0]->attributes->{$attrib} =~ m/^$value$/i) {
    				$match++;
       	 		}
       	 	}
       	 	else {
       	 		$match++;
       	 	}
       	}
        if ($match == 0){
            push @found, $_[0];
       	    return $retvalue;
        }   
        1}});
    return wantarray? @found : @found ? $found[0] : undef;
}


1;