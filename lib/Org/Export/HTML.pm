package Org::Export::HTML;
# ABSTRACT: Export Org document to HTML

use 5.010;
use Moo;
use experimental 'smartmatch';
use Log::Any '$log';

# VERSION
# DATE

use File::Slurp::Tiny qw(read_file write_file);
use HTML::Entities qw/encode_entities/;
use List::Util;
use Org::Document qw/first/;
use String::Escape qw/elide printable/;

=head1 ATTRIBUTES

=cut

=head2 naked => BOOL

If set to true, export_document() will not output HTML/HEAD/BODY wrapping
element. Default is false.

=cut

has naked => (is => 'rw');

=head2 include_tags => ARRAYREF

Works like Org's 'org-export-select-tags' variable. See export_org_to_html() for
more details.

=cut

has include_tags => (is => 'rw');

=head2 exclude_tags => ARRAYREF

After 'include_tags' is evaluated, all subtrees that are marked by any of the
exclude tags will be removed from export.

=cut

has exclude_tags => (is => 'rw');

=head2 html_title => STR

Title to use in TITLE element. If unset, defaults to "(no title)" when
exporting.

=cut

has html_title => (is => 'rw');

=head2 css_url => STR

If set, export_document() will output a LINK element pointing to this CSS.

=cut

has css_url => (is => 'rw');


require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(export_org_to_html);

our %SPEC;
$SPEC{export_org_to_html} = {
    summary => 'Export Org document to HTML',
    description => <<'_',

This is the non-OO interface. For more customization, consider subclassing
Org::Export::HTML.

_
    args => {
        source_file => ['str' => {
            summary => 'Source Org file to export',
        }],
        source_str => ['str' => {
            summary => 'Alternatively you can specify Org string directly',
        }],
        target_file => ['str' => {
            summary => 'HTML file to write to',
            description => <<'_',

If not specified, HTML string will be returned.

_
        }],
        include_tags => ['array' => {
            of => 'str*',
            summary => 'Include trees that carry one of these tags',
            description => <<'_',

Works like Org's 'org-export-select-tags' variable. If the whole document
doesn't have any of these tags, then the whole document will be exported.
Otherwise, trees that do not carry one of these tags will be excluded. If a
selected tree is a subtree, the heading hierarchy above it will also be selected
for export, but not the text below those headings.

_
        }],
        exclude_tags => ['array' => {
            of => 'str*',
            summary => 'Exclude trees that carry one of these tags',
            description => <<'_',

After 'include_tags' is evaluated, all subtrees that are marked by any of the
exclude tags will be removed from export.

_
        }],
        html_title => ['str' => {
            summary => 'HTML document title, defaults to source_file',
        }],
        css_url => ['str' => {
            summary => 'Add a link to CSS document',
        }],
        naked => ['bool' => {
            summary => 'Don\'t wrap exported HTML with HTML/HEAD/BODY elements',
        }],
    }
};
sub export_org_to_html {
    my %args = @_;

    my $doc;
    if ($args{source_file}) {
        $doc = Org::Document->new(from_string =>
                                      scalar read_file($args{source_file}));
    } elsif (defined($args{source_str})) {
        $doc = Org::Document->new(from_string => $args{source_str});
    } else {
        return [400, "Please specify source_file/source_str"];
    }

    my $include_tags = $args{include_tags};
    if ($include_tags) {
        my $doc_has_include_tags;
        for my $h ($doc->find('Org::Element::Headline')) {
            my @htags = $h->get_tags;
            if (defined(first {$_ ~~ @htags} @$include_tags)) {
                $doc_has_include_tags++;
                last;
            }
        }
        $include_tags = undef unless $doc_has_include_tags;
    }

    my $obj = __PACKAGE__->new(
        include_tags => $include_tags,
        exclude_tags => $args{exclude_tags},
        css_url      => $args{css_url},
        naked        => $args{naked},
        html_title   => $args{html_title} // $args{source_file},
    );

    my $html = $obj->export($doc);
    #$log->tracef("html = %s", $html);
    if ($args{target_file}) {
        write_file($args{target_file}, $html);
        return [200, "OK"];
    } else {
        return [200, "OK", $html];
    }
}

=head1 METHODS

=for Pod::Coverage BUILD

=head2 $oeh->export($doc)

Export an Org document into HTML. $org is L<Org::Document> object. Returns
$html, which is the HTML string. Dies on error.

=cut

sub export {
    my ($self, $elem) = @_;
    $self->_export_elems($elem);
}

=head2 $oeh->export_document($doc) => $html

Given an L<Org::Element::Block> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_document {
    my ($self, $doc) = @_;

    my $html = [];
    unless ($self->naked) {
        push @$html, "<HTML>\n";
        push @$html, (
            "<!-- Generated by ".__PACKAGE__,
            " version ".($VERSION // "?"),
            " on ".scalar(localtime)." -->\n\n");

        push @$html, "<HEAD>\n";
        push @$html, "<TITLE>",
            ($self->html_title // "(no title)"), "</TITLE>\n";
        if ($self->css_url) {
            push @$html, (
                "<LINK REL=\"stylesheet\" TYPE=\"text/css\" HREF=\"",
                $self->css_url, "\" />\n"
            );
        }
        push @$html, "</HEAD>\n\n";

        push @$html, "<BODY>\n";
    }
    push @$html, $self->_export_elems(@{$doc->children});
    unless ($self->naked) {
        push @$html, "</BODY>\n\n";
        push @$html, "</HTML>\n";
    }

    join "", @$html;
}

=head2 $oeh->export_block($elem) => $html

Given an L<Org::Element::Block> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_block {
    my ($self, $elem) = @_;
    # currently all assumed to be <PRE>
    join "", (
        "<PRE CLASS=\"block block_", lc($elem->name), "\">",
        encode_entities($elem->raw_content),
        "</PRE>\n\n"
    );
}

=head2 $oeh->export_short_example($elem) => $html

Given an L<Org::Element::ShortExample> element, export it to HTML. Override this
in subclass to provide custom behavior.

=cut

sub export_short_example {
    my ($self, $elem) = @_;
    join "", (
        "<PRE CLASS=\"short_example\">",
        encode_entities($elem->example),
        "</PRE>\n"
    );
}

=head2 $oeh->export_comment($elem) => $html

Given an L<Org::Element::Comment> element, export it to HTML. Override this
in subclass to provide custom behavior.

=cut

sub export_comment {
    my ($self, $elem) = @_;
    join "", (
        "<!-- ",
        encode_entities($elem->_str),
        " -->\n"
    );
}

=head2 $oeh->export_drawer($elem) => $html

Given an L<Org::Element::Drawer> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_drawer {
    my ($self, $elem) = @_;
    # currently not exported
    '';
}

=head2 $oeh->export_footnote($elem) => $html

Given an L<Org::Element::Footnote> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_footnote {
    my ($self, $elem) = @_;
    # currently not exported
    '';
}

=head2 $oeh->export_headline($elem) => $html

Given an L<Org::Element::Headline> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_headline {
    my ($self, $elem) = @_;

    my @htags = $elem->get_tags;
    my @children = @{$elem->children // []};
    if ($self->include_tags) {
        if (!defined(first {$_ ~~ @htags} @{$self->include_tags})) {
            # headline doesn't contain include_tags, select only
            # suheadlines that contain them
            @children = ();
            for my $c (@{ $elem->children // []}) {
                next unless $c->isa('Org::Element::Headline');
                my @hl_included = $elem->find(
                    sub {
                        my $el = shift;
                        return unless
                            $elem->isa('Org::Element::Headline');
                        my @t = $elem->get_tags;
                        return defined(first {$_ ~~ @t}
                                           @{$self->include_tags});
                    });
                next unless @hl_included;
                push @children, $c;
            }
            return '' unless @children;
        }
    }
    if ($self->exclude_tags) {
        return '' if defined(first {$_ ~~ @htags}
                                 @{$self->exclude_tags});
    }

    join "", (
        "<H" , $elem->level, ">",
        $self->_export_elems($elem->title),
        "</H", $elem->level, ">\n\n",
        $self->_export_elems(@children)
    );
}

=head2 $oeh->export_list($elem) => $html

Given an L<Org::Element::List> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_list {
    my ($self, $elem) = @_;
    my $tag;
    my $type = $elem->type;
    if    ($type eq 'D') { $tag = 'DL' }
    elsif ($type eq 'O') { $tag = 'OL' }
    elsif ($type eq 'U') { $tag = 'UL' }
    join "", (
        "<$tag>\n",
        $self->_export_elems(@{$elem->children // []}),
        "</$tag>\n\n"
    );
}

=head2 $oeh->export_list_item($elem) => $html

Given an L<Org::Element::ListItem> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_list_item {
    my ($self, $elem) = @_;

    my $html = [];
    if ($elem->desc_term) {
        push @$html, "<DT>";
    } else {
        push @$html, "<LI>";
    }

    if ($elem->check_state) {
        push @$html, "<STRONG>[", $elem->check_state, "]</STRONG>";
    }

    if ($elem->desc_term) {
        push @$html, $self->_export_elems($elem->desc_term);
        push @$html, "</DT>";
        push @$html, "<DD>";
    }

    push @$html, $self->_export_elems(@{$elem->children}) if $elem->children;

    if ($elem->desc_term) {
        push @$html, "</DD>\n";
    } else {
        push @$html, "</LI>\n";
    }

    join "", @$html;
}

=head2 $oeh->export_radio_target($elem) => $html

Given an L<Org::Element::RadioTarget> element, export it to HTML. Override this
in subclass to provide custom behavior.

=cut

sub export_radio_target {
    my ($self, $elem) = @_;
    # currently not exported
    '';
}

=head2 $oeh->export_setting($elem) => $html

Given an L<Org::Element::Setting> element, export it to HTML. Override this
in subclass to provide custom behavior.

=cut

sub export_setting {
    my ($self, $elem) = @_;
    # currently not exported
    '';
}

=head2 $oeh->export_table($elem) => $html

Given an L<Org::Element::Table> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_table {
    my ($self, $elem) = @_;
    join "", (
        "<TABLE BORDER>\n",
        $self->_export_elems(@{$elem->children // []}),
        "</TABLE>\n\n"
    );
}

=head2 $oeh->export_table_row($elem) => $html

Given an L<Org::Element::TableRow> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_table_row {
    my ($self, $elem) = @_;
    join "", (
        "<TR>",
        $self->_export_elems(@{$elem->children // []}),
        "</TR>\n"
    );
}

=head2 $oeh->export_table_cell($elem) => $html

Given an L<Org::Element::TableCell> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_table_cell {
    my ($self, $elem) = @_;

    join "", (
        "<TD>",
            $self->_export_elems(@{$elem->children // []}),
        "</TD>"
    );
}

=head2 $oeh->export_table_vline($elem) => $html

Given an L<Org::Element::TableVLine> element, export it to HTML. Override this
in subclass to provide custom behavior.

=cut

sub export_table_vline {
    my ($self, $elem) = @_;
    # currently not exported
    '';
}

=head2 $oeh->export_target($elem) => $html

Given an L<Org::Element::Target> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_target {
    my ($self, $elem) = @_;
    # target
    join "", (
        "<A NAME=\"", __escape_target($elem->target), "\">"
    );
}

=head2 $oeh->export_text($elem) => $html

Given an L<Org::Element::Text> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_text {
    my ($self, $elem) = @_;

    my $style = $elem->style;
    my $tag;
    if    ($style eq 'B') { $tag = 'B' }
    elsif ($style eq 'I') { $tag = 'I' }
    elsif ($style eq 'U') { $tag = 'U' }
    elsif ($style eq 'S') { $tag = 'STRIKE' }
    elsif ($style eq 'C') { $tag = 'CODE' }
    elsif ($style eq 'V') { $tag = 'TT' }

    my $html = [];

    push @$html, "<$tag>" if $tag;
    my $text = encode_entities($elem->text);
    $text =~ s/\R\R/\n\n<p>\n\n/g;
    push @$html, $text;
    push @$html, $self->_export_elems(@{$elem->children}) if $elem->children;
    push @$html, "</$tag>" if $tag;

    join "", @$html;
}

=head2 $oeh->export_time_range($elem) => $html

Given an L<Org::Element::TimeRange> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_time_range {
    my ($self, $elem) = @_;

    $elem->as_string;
}

=head2 $oeh->export_timestamp($elem) => $html

Given an L<Org::Element::Timestamp> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_timestamp {
    my ($self, $elem) = @_;

    $elem->as_string;
}

=head2 $oeh->export_link($elem) => $html

Given an L<Org::Element::Link> element, export it to HTML. Override this in
subclass to provide custom behavior.

=cut

sub export_link {
    my ($self, $elem) = @_;

    my $html = [];
    push @$html, "<A HREF=\"";
    if ($elem->link =~ m!^\w+:!) {
        # looks like a url
        push @$html, $elem->link;
    } else {
        # assume it's an anchor
        push @$html, "#", __escape_target($elem->link);
    }
    push @$html, "\">";
    if ($elem->description) {
        push @$html, $self->_export_elems($elem->description);
    } else {
        push @$html, $elem->link;
    }
    push @$html, "</A>";

    join "", @$html;
}

sub _export_elems {
    my ($self, @elems) = @_;

    my $html = [];
  ELEM:
    for my $elem (@elems) {
        $log->tracef("exporting element %s (%s) ...", ref($elem),
                     elide(printable($elem->as_string), 30));
        my $elc = ref($elem);

        if ($elc eq 'Org::Element::Block') {
            push @$html, $self->export_block($elem);
        } elsif ($elc eq 'Org::Element::ShortExample') {
            push @$html, $self->export_short_example($elem);
        } elsif ($elc eq 'Org::Element::Comment') {
            push @$html, $self->export_comment($elem);
        } elsif ($elc eq 'Org::Element::Drawer') {
            push @$html, $self->export_drawer($elem);
        } elsif ($elc eq 'Org::Element::Footnote') {
            push @$html, $self->export_footnote($elem);
        } elsif ($elc eq 'Org::Element::Headline') {
            push @$html, $self->export_headline($elem);
        } elsif ($elc eq 'Org::Element::List') {
            push @$html, $self->export_list($elem);
        } elsif ($elc eq 'Org::Element::ListItem') {
            push @$html, $self->export_list_item($elem);
        } elsif ($elc eq 'Org::Element::RadioTarget') {
            push @$html, $self->export_radio_target($elem);
        } elsif ($elc eq 'Org::Element::Setting') {
            push @$html, $self->export_setting($elem);
        } elsif ($elc eq 'Org::Element::Table') {
            push @$html, $self->export_table($elem);
        } elsif ($elc eq 'Org::Element::TableCell') {
            push @$html, $self->export_table_cell($elem);
        } elsif ($elc eq 'Org::Element::TableRow') {
            push @$html, $self->export_table_row($elem);
        } elsif ($elc eq 'Org::Element::TableVLine') {
            push @$html, $self->export_table_vline($elem);
        } elsif ($elc eq 'Org::Element::Target') {
            push @$html, $self->export_target($elem);
        } elsif ($elc eq 'Org::Element::Text') {
            push @$html, $self->export_text($elem);
        } elsif ($elc eq 'Org::Element::Link') {
            push @$html, $self->export_link($elem);
        } elsif ($elc eq 'Org::Element::TimeRange') {
            push @$html, $self->export_time_range($elem);
        } elsif ($elc eq 'Org::Element::Timestamp') {
            push @$html, $self->export_timestamp($elem);
        } elsif ($elc eq 'Org::Document') {
            push @$html, $self->export_document($elem);
        } else {
            warn "Don't know how to export $elc element, skipped";
            push @$html, $self->_export_elems(@{$elem->children})
                if $elem->children;
        }
    }

    join "", @$html;
}

sub __escape_target {
    my $target = shift;
    $target =~ s/[^\w]+/_/g;
    $target;
}

1;
__END__

=head1 SYNOPSIS

 use Org::Export::HTML qw(export_org_to_html);

 # non-OO interface
 my $res = export_org_to_html(
     source_file   => 'todo.org', # or source_str
     #target_file  => 'todo.html', # defaults return the HTML in $res->[2]
     #html_title   => 'My Todo List', # defaults to file name
     #include_tags => [...], # default exports all tags.
     #exclude_tags => [...], # behavior mimics emacs's include/exclude rule
     #css_url      => '/path/to/my/style.css', # default none
     #naked        => 0, # if set to 1, no HTML/HEAD/BODY will be output.
 );
 die "Failed" unless $res->[0] == 200;

 # OO interface
 my $oeh = Org::Export::HTML->new();
 my $html = $oeh->export($doc); # $doc is Org::Document object

=head1 DESCRIPTION

Export Org format to HTML. Currently very barebones; this module is more of a
proof-of-concept for L<Org::Parser>. For any serious exporting, currently you're
better-off using Emacs' org-mode HTML export facility.

This module uses L<Log::Any> logging framework.

This module uses L<Moo> for object system.


=head1 FUNCTIONS

None is exported by default, but they can be.


=head1 SEE ALSO

L<Org::Parser>

=cut
