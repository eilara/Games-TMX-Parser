package Games::TMX::Parser;

use Moose;
use MooseX::Types::Moose qw(Str);
use File::Spec;
use XML::Twig;

has [qw(map_dir map_file)] => (is => 'ro', isa => Str, required => 1);

has map => (is => 'ro', lazy_build => 1, handles => [qw(get_layer)]);

has twig => (is => 'ro', lazy_build => 1);

sub _build_twig {
    my $self = shift;
    my $twig = XML::Twig->new;
    $twig->parsefile
        ( File::Spec->catfile($self->map_dir, $self->map_file) );
    return $twig;
}

sub _build_map {
    my $self = shift;
    return Games::TMX::Parser::Map->new(el => $self->twig->root);
}

# ------------------------------------------------------------------------------

package Games::TMX::Parser::MapElement;

use Moose;

has el => (is => 'ro', required => 1, handles => [qw(
    att att_exists first_child children print
)]);

# ------------------------------------------------------------------------------

package Games::TMX::Parser::Map;

use Moose;

extends 'Games::TMX::Parser::MapElement';

has [qw(layers tilesets width height tile_width tile_height tiles_by_id)] =>
    (is => 'ro', lazy_build => 1);

sub _build_layers {
    my $self = shift;
    return {map { $_->att('name') =>
        Games::TMX::Parser::Layer->new(el => $_, map => $self)
    } $self->children('layer') };
}

sub _build_tiles_by_id {
    my $self  = shift;
    my @tiles = map { @{$_->tiles} } @{ $self->tilesets };
    return {map { $_->id => $_ } @tiles};
}

sub _build_tilesets {
    my $self = shift;
    return [map {
        Games::TMX::Parser::TileSet->new(el => $_)
    } $self->children('tileset') ];
}

sub _build_width       { shift->att('width') }
sub _build_height      { shift->att('height') }
sub _build_tile_width  { shift->att('tile_width') }
sub _build_tile_height { shift->att('tile_height') }

sub get_layer { shift->layers->{pop()} }
sub get_tile  { shift->tiles_by_id->{pop()} }

# ------------------------------------------------------------------------------

package Games::TMX::Parser::TileSet;

use Moose;
use MooseX::Types::Moose qw(Str);
use List::MoreUtils qw(natatime);

extends 'Games::TMX::Parser::MapElement';

has [qw(first_gid image tiles width height tile_width tile_height tile_count)] =>
    (is => 'ro', lazy_build => 1);

sub _build_tiles {
    my $self = shift;
    my $first_gid = $self->first_gid;

    # index tiles with properties
    my $prop_tiles = {map {
        my $el = $_;
        my $id = $first_gid + $el->att('id');
        my $properties = {map {
           $_->att('name'), $_->att('value') 
        } $el->first_child('properties')->children};
        my $tile = Games::TMX::Parser::Tile->new
            (id => $id, properties => $properties);
        ($id => $tile);
    } $self->children('tile')};

    # create a tile object for each tile in the tileset
    # unless it is a tile with properties
    my @tiles;
    my $it = natatime $self->width, 1..$self->tile_count;
    while (my @ids = $it->()) {
        for my $id (@ids) {
            my $gid = $first_gid + $id;
            my $tile = $prop_tiles->{$gid} || 
                Games::TMX::Parser::Tile->new(id => $gid);
            push @tiles, $tile;
        }
    }
    return [@tiles];
}

sub _build_tile_count {
    my $self = shift;
    return ($self->width      * $self->height     ) /
           ($self->tile_width * $self->tile_height);
}

sub _build_first_gid   { shift->att('firstgid') }
sub _build_tile_width  { shift->att('tilewidth') }
sub _build_tile_height { shift->att('tileheight') }
sub _build_image       { shift->first_child('image')->att('source') }
sub _build_width       { shift->first_child('image')->att('width') }
sub _build_height      { shift->first_child('image')->att('height') }

# ------------------------------------------------------------------------------

package Games::TMX::Parser::Tile;

use Moose;
use MooseX::Types::Moose qw(Int HashRef);

has id => (is => 'ro', isa => Int, required => 1);

has properties => (is => 'ro', isa => HashRef, default => sub { {} });

# ------------------------------------------------------------------------------

package Games::TMX::Parser::Layer;

use Moose;
use List::MoreUtils qw(natatime);

has map => (is => 'ro', required => 1, weak_ref => 1, handles => [qw(
    width height tile_width tile_height get_tile
)]);

has rows => (is => 'ro', lazy_build => 1);

extends 'Games::TMX::Parser::MapElement';

sub _build_rows {
    my $self = shift;
    my @rows;
    my $it = natatime $self->width, $self->first_child->children('tile');
    my $y = 0;
    while (my @row = $it->()) {
        my $x = 0;
        push @rows, [map {
            my $el = $_;
            my $id = $el->att('gid');
            my $tile;
            $tile = $self->get_tile($id) if $id;
            Games::TMX::Parser::Cell->new
                (x => $x++, y => $y, tile => $tile, layer => $self)
        } @row];
        $y++;
    }
    return [@rows];
}

sub find_cells_with_property {
    my ($self, $prop) = @_;
    return grep {
        my $cell = $_;
        my $tile = $cell->tile;
        $tile && exists $tile->properties->{$prop};
    } $self->all_cells;
}

sub get_cell {
    my ($self, $col, $row) = @_;
    return $self->rows->[$row]->[$col];
}

sub all_cells { return map { @$_ } @{ shift->rows } }

# ------------------------------------------------------------------------------

package Games::TMX::Parser::Cell;

use Moose;
use MooseX::Types::Moose qw(Int);

has [qw(x y)] => (is => 'ro', isa => Int, required => 1);

has tile => (is => 'ro');

has layer => (is => 'ro', required => 1, weak_ref => 1, handles => [qw(
    get_cell width height
)]);

my %Dirs      = map { $_ => 1 } qw(below left right above);
my %Anti_Dirs = (below => 'above', left => 'right', right => 'left', above => 'below');

sub left  { shift->neighbor(-1, 0) }
sub right { shift->neighbor( 1, 0) }
sub above { shift->neighbor( 0,-1) }
sub below { shift->neighbor( 0, 1) }

sub xy { ($_[0]->x, $_[0]->y) }

sub neighbor {
    my ($self, $dx, $dy) = @_;
    my $x = $self->x + $dx;
    my $y = $self->y + $dy;
    return undef if $x < 0            || $y < 0;
    return undef if $x > $self->width || $y > $self->height;
    return $self->get_cell($x, $y);
}

sub seek_next_cell {
    my ($self, $dir) = @_;
    my %dirs = %Dirs;
    delete $dirs{$Anti_Dirs{$dir}} if $dir;
    for my $d (keys %dirs) {
        my $c = $self->$d;
        return [$c, $d] if $c && $c->tile;
    }
    return undef;
}

1;
