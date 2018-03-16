use v6;

class PDF::Render::Cairo {

# A lightweight draft renderer for PDF to PNG or SVG
# Aim is preview output for PDF::Content generated PDF's
#
    use PDF::Class;
    use PDF::XObject::Image;
    use Cairo:ver(v0.2.1+);
    use Color;
    use PDF::Content::Graphics;
    use PDF::Content::Ops :OpCode, :LineCaps, :LineJoin, :TextMode;
    use PDF::Render::Cairo::FontLoader;

    has PDF::Content::Ops $.gfx;
    has $.content is required handles <width height>;
    has Cairo::Surface $.surface = Cairo::Image.create(Cairo::FORMAT_ARGB32, self.width, self.height);
    has Cairo::Context $.ctx = Cairo::Context.new: $!surface;
    has List $.current-font;
    method current-font { $!current-font[0] }
    has Hash @!save;
    has Numeric $!tx = 0.0;
    has Numeric $!ty = 0.0;
    has Numeric $!hscale = 1.0;
    my class Cache {
        has Cairo::Surface %.form{Any};
        has Cairo::Surface %.pattern{Any};
        has %.font;
    }
    has Cache $.cache .= new;

    submethod TWEAK(:$!gfx = $!content.gfx(:!render),
                    Bool :$feed = True,
                    Bool :$transparent = False,
        ) {
        self!init: :$transparent;
        $!gfx.callback.push: self.callback
            if $feed;
    }

    method render(|c --> Cairo::Surface) {
        my $obj = self.new( :!feed, |c);
        my $content = $obj.content;
        if $content.has-pre-gfx {
            my $gfx = $content.new-gfx: :callback[ $obj.callback ];
            $gfx.ops: $content.pre-gfx.ops;
        }
        temp $obj.gfx.callback = [ $obj.callback ];
        $content.render($obj.gfx);
        $obj.surface;
    }

    method !init(:$transparent) {
        $!ctx.translate(0, self.height);
        $!ctx.line_width = $!gfx.LineWidth;
        unless $transparent {
            $!ctx.rgb(1.0, 1.0, 1.0);
            $!ctx.paint;
        }
    }

    method !coords(Numeric \x, Numeric \y) {
        (x, -y);
    }

    method !set-color($_, $alpha) {
        my ($cs, $colors) = .kv;
        given $cs {
            when 'DeviceRGB' {
                $!ctx.rgba( |$colors, $alpha );
            }
            when 'DeviceGray' {
                my @rgb = $colors[0] xx 3;
                $!ctx.rgba( |@rgb, $alpha );
            }
            when 'DeviceCMYK' {
                my Color $color .= new: :cmyk($colors);
                my @rgb = $color.rgb.map: * / 255;
                $!ctx.rgba( |@rgb, $alpha );
            }
            when 'Pattern' {
                with $colors[0] {
                    with $!gfx.resource-entry('Pattern', $_) -> $pattern {
                        given $pattern.PatternType {
                            when 1 { # Tiling
                                my $img = self!make-tiling-pattern($pattern);
                                $!ctx.pattern: $img;
                            }
                            when 2 { # Shading
                                warn "can't do type-2 patterns (Shading) yet";
                                Mu;
                            }
                        }
                    }
                }
            }
            default {
                warn "can't handle colorspace: $_";
            }
        }
    }

    method !set-stroke-color { self!set-color($!gfx.StrokeColor, $!gfx.StrokeAlpha) }
    method !set-fill-color { self!set-color($!gfx.FillColor, $!gfx.FillAlpha) }

    method Save()      {
        $!ctx.save;
        @!save.push: %( :$!current-font );
    }
    method Restore()   {
        $!ctx.restore;
        if @!save {
            with @!save.pop {
                $!current-font = .<current-font>;
            }
        }
    }
    method ClosePath() { $!ctx.close_path; }
    method Stroke()    {
        self!set-stroke-color;
        $!ctx.stroke;
    }
    method Fill(:$preserve=False) {
        self!set-fill-color;
        $!ctx.fill(:$preserve);
    }
    method FillStroke {
        self.Fill(:preserve);
        self.Stroke;
    }
    method CloseStroke {
        self.ClosePath;
        self.Stroke;
    }
    method CloseFillStroke {
        self.ClosePath;
        self.Fill(:preserve);
        self.Stroke;
    }
    method EOFill {
        $!ctx.fill_rule = Cairo::FILL_RULE_EVEN_ODD;
        self.Fill;
        $!ctx.fill_rule = Cairo::FILL_RULE_WINDING;
    }
    method EOFillStroke {
        $!ctx.fill_rule = Cairo::FILL_RULE_EVEN_ODD;
        self.FillStroke;
        $!ctx.fill_rule = Cairo::FILL_RULE_WINDING;
    }
    method CloseEOFillStroke {
        $!ctx.fill_rule = Cairo::FILL_RULE_EVEN_ODD;
        self.CloseFillStroke;
        $!ctx.fill_rule = Cairo::FILL_RULE_WINDING;
    }
    method SetStrokeRGB(*@) {}
    method SetFillRGB(*@) {}
    method SetStrokeCMYK(*@) {}
    method SetFillCMYK(*@) {}
    method SetStrokeGray(*@) {}
    method SetFillGray(*@) {}
    method SetStrokeColorSpace($_) {}
    method SetFillColorSpace($_) {}
    method SetStrokeColorN(*@) {}
    method SetFillColorN(*@) {}

    method EndPath() { $!ctx.new_path }

    method MoveTo(Numeric $x, Numeric $y) {
        $!ctx.move_to: |self!coords($x,$y);
    }

    method LineTo(Numeric $x, Numeric $y) {
        $!ctx.line_to: |self!coords($x,$y);
    }

    method SetLineCap(UInt $lc) {
        $!ctx.line_cap = do given $lc {
            when ButtCaps   { Cairo::LINE_CAP_BUTT }
            when RoundCaps  { Cairo::LINE_CAP_ROUND }
            when SquareCaps { Cairo::LINE_CAP_SQUARE }
        }
    }

    method SetLineJoin(UInt $lc) {
        $!ctx.line_join = do given $lc {
            when MiterJoin  { Cairo::LINE_JOIN_MITER }
            when RoundJoin  { Cairo::LINE_JOIN_ROUND }
            when BevelJoin  { Cairo::LINE_JOIN_BEVEL }
        }
    }

    method SetDashPattern(Array $pattern, Numeric $phase) {
        $!ctx.set_dash($pattern, $pattern.elems, $phase);
    }

    method SetLineWidth(Numeric $lw) {
        $!ctx.line_width = $lw;
    }

    method SetGraphicsState($gs) { }

    method CurveTo(Numeric $x1, Numeric $y1, Numeric $x2, Numeric $y2, Numeric $x3, Numeric $y3) {
        my \c1 = |self!coords($x1, $y1);
        my \c2 = |self!coords($x2, $y2);
        my \c3 = |self!coords($x3, $y3);
        $!ctx.curve_to(|c1, |c2, |c3);
    }

    method CurveToInitial(Numeric $x1, Numeric $y1, Numeric $x2, Numeric $y2) {
        my \c1 = |self!coords($x1, $y1);
        my \c2 = |self!coords($x2, $y2);
        $!ctx.curve_to(|c1, |c2, |c2);
    }

    method Rectangle(Numeric $x, Numeric $y, Numeric $w, Numeric $h) {
        $!ctx.rectangle( |self!coords($x, $y), $w, - $h);
    }

    method Clip {
        $!ctx.clip;
    }

    sub matrix-to-cairo(Num(Numeric) $scale-x, Num(Numeric) $skew-x,
                        Num(Numeric) $skew-y,  Num(Numeric) $scale-y,
                        Num(Numeric) $trans-x, Num(Numeric) $trans-y) {

       Cairo::Matrix.new.init(
            :xx($scale-x), :yy($scale-y),
            :yx(-$skew-x), :xy(-$skew-y),
            :x0($trans-x), :y0(-$trans-y),
            );
    }

    method !concat-matrix(*@matrix) {
        my $transform = matrix-to-cairo(|@matrix);
        $!ctx.transform( $transform );
    }
    method ConcatMatrix(*@matrix) {
        self!concat-matrix(|@matrix);
    }
    method BeginText() { $!tx = 0.0; $!ty = 0.0; }
    method SetFont($font-key, $font-size) {
        $!ctx.set_font_size($font-size);
        with $!gfx.resource-entry('Font', $font-key) {
            $!current-font = $!cache.font{$font-key} //= do {
                my $font-obj = PDF::Render::Cairo::FontLoader.load-font: :dict($_);
                my $ft-face = $font-obj.face.struct;
                my Cairo::Font $cairo-font .= create(
                    $ft-face, :free-type,
                );
                [$font-obj, $cairo-font]
            }
            $!ctx.set_font_face($!current-font[1]);
        }
        else {
            warn "unable to locate Font in resource dictionary: $font-key";
            $!current-font = [PDF::Content::Util::Font.core-font('courier'), ];
            $!ctx.select_font_face('courier', Cairo::FONT_WEIGHT_NORMAL, Cairo::FONT_SLANT_NORMAL);
        }
    }
    method SetTextMatrix(*@) {
        $!tx = 0.0;
        $!ty = 0.0;
    }
    method TextMove(Numeric, Numeric) {
        $!tx = 0.0;
        $!ty = 0.0;
    }
    method SetTextRender(Int) { }
    method !show-text($text) {
        my \text-render = $!gfx.TextRender;

        $!ctx.move_to($!tx / $!hscale, $!ty - $!gfx.TextRise);

        given text-render {
            when FillText {
                self!set-fill-color;
                $!ctx.show_text($text);
            }
            when InvisableText {
            }
            default { # other modes
                my \fill = ?(text-render == FillText|FillOutlineText|FillClipText|FillOutlineClipText);
                my \stroke = ?(text-render == OutlineText|FillOutlineText|OutlineClipText|FillOutlineClipText);
                my \clip = ?(text-render == FillClipText|OutlineClipText|ClipText);

                $!ctx.text_path($text);

                if fill {
                    self!set-fill-color;
                    $!ctx.fill: :preserve(stroke||clip);
                }

                if stroke {
                    self!set-stroke-color;
                    $!ctx.stroke: :preserve(clip);
                }
           }
        }
        $!tx += $!ctx.text_extents($text).x_advance * $!hscale;
        $!ty += $!ctx.text_extents($text).y_advance;
    }

    method !text(&stuff) {
        $!ctx.save;
        self!concat-matrix(|$!gfx.TextMatrix);
        $!hscale = $!gfx.HorizScaling / 100.0;
        $!ctx.scale($!hscale, 1)
            unless $!hscale =~= 1.0;
        &stuff();
        $!ctx.restore;
    }

    method ShowText($text-encoded) {
        self!text: {
            self!show-text: $.current-font.decode($text-encoded, :str);
        }
    }
    method ShowSpaceText(List $text) {
        self!text: {
            my Numeric $font-size = $!gfx.Font[1];
            for $text.list {
                when Str {
                    self!show-text: $.current-font.decode($_, :str);
                }
                when Numeric {
                    $!tx -= $_ * $font-size / 1000;
                }
            }
        }
    }
    method SetTextLeading($) { }
    method SetTextRise($) { }
    method SetHorizScaling($) { }
    method TextNextLine() {
        $!tx = 0.0;
        $!ty = 0.0;
    }
    method TextMoveSet(Numeric, Numeric) {
        $!tx = 0.0;
        $!ty = 0.0;
    }
    method MoveShowText($text-encoded) {
        $!tx = 0.0;
        $!ty = 0.0;
        self.ShowText($text-encoded);
    }
    method MoveSetShowText(Numeric, Numeric, $text-encoded) {
        self.MoveShowText($text-encoded);
    }
    method EndText()  { $!tx = 0.0; $!ty = 0.0; }

    method !make-form($xobject) {
        $!cache.form{$xobject} //= self.render: :content($xobject), :transparent, :$!cache;
    }
    need PDF::Pattern::Tiling;
    method !make-tiling-pattern(PDF::Pattern::Tiling $pattern) {
        my $img = $!cache.pattern{$pattern} //= do {
            my $image = self.render: :content($pattern), :transparent, :$!cache;
            my $padded-img = Cairo::Image.create(
                Cairo::FORMAT_ARGB32,
                $pattern<XStep> // $image.width,
                $pattern<YStep> // $image.height);
            my Cairo::Context $ctx .= new($padded-img);
            $ctx.set_source_surface($image);
            $ctx.paint;
            $padded-img;
        }
        my Cairo::Pattern::Surface $patt .= create($img.surface);
        $patt.extend = Cairo::Extend::EXTEND_REPEAT;
        my $ctm = matrix-to-cairo(|$!gfx.CTM);
        $patt.matrix = $ctm.multiply(matrix-to-cairo(|$_).invert)
            with $pattern.Matrix;
        $patt;
    }
    method !make-image(PDF::XObject::Image $xobject) {
        $!cache.form{$xobject} //= do {
            my Cairo::Image $surface;
            try {
                CATCH {
                    when X::NYI {
                        # draw stub placeholder rectangle
                        warn "stubbing image: {$xobject.perl}";
                        $surface .= create(Cairo::FORMAT_ARGB32, $xobject.width, $xobject.height);
                        my Cairo::Context $ctx .= new: $surface;
                        $ctx.new_path;
                        $ctx.rgba(.8,.8,.6, .5);
                        $ctx.rectangle(0, 0, $xobject.width, $xobject.height);
                        $ctx.fill(:preserve);
                        $ctx.rgba(.3,.3,.3, .5);
                        $ctx.line_width = 2;
                        $ctx.stroke;
                        $surface;
                    }
                }

                $surface = Cairo::Image.create($xobject.to-png.Buf);
            }
            $surface;
        }
    }
    method XObject($key) {
        with $!gfx.resource-entry('XObject', $key) -> $xobject {
            $!ctx.save;

            my $surface = do given $xobject<Subtype> {
                when 'Form' {
                    self!make-form($xobject);
                }
                when 'Image' {
                    $!ctx.scale( 1/$xobject.width, 1/$xobject.height );
                    self!make-image($xobject);
                }
            }

            with $surface {
                $!ctx.translate(0, -$xobject.height);
                $!ctx.set_source_surface($_);
                $!ctx.paint_with_alpha($!gfx.FillAlpha);
            }

            $!ctx.restore;
        }
        else {
            warn "unable to locate XObject in resource dictionary: $key";
        }
    }

    method BeginMarkedContent(Str) { }
    method BeginMarkedContentDict(Str, Hash) { }
    method EndMarkedContent() { }

    method callback{
        sub ($op, *@args) {
            my $method = OpCode($op).key;
            self."$method"(|@args);
            given $!ctx.status -> $status {
                die "bad Cairo status $status {Cairo::cairo_status_t($status).key} after $method\({@args}\) operation"
                    if $status;
            }
        }
    }

    our %nyi;
    method FALLBACK($method, *@args) {
        if $method ~~ /^<[A..Z]>/ {
            # assume unimplemented operator
            %nyi{$method} //= do {warn "can't do: $method\(@args[]\) yet";}
        }
        else {
            die X::Method::NotFound.new( :$method, :typename(self.^name) );
        }
    }

    multi method save-as-image(PDF::Content::Graphics $content, Str $filename where /:i '.png' $/) {
        my $surface = self.render: :$content;
        $surface.write_png: $filename;
    }

    multi method save-as-image(PDF::Content::Graphics $content, Str $filename where /:i '.svg' $/, :$cache = Cache.new;) {
        my $surface = Cairo::Surface::SVG.create($filename, $content.width, $content.height);
        my $feed = self.render: :$content, :$surface, :$cache;
        $surface.finish;
    }

    multi method save-as(PDF::Class $pdf, Str(Cool) $outfile where /:i '.'('png'|'svg') $/) {
        my \format = $0.lc;
        my UInt $pages = $pdf.page-count;
        my $cache = Cache.new;

        for 1 .. $pages -> UInt $page-num {

            my $img-filename = $outfile;
            if $outfile.index("%").defined {
                $img-filename = $outfile.sprintf($page-num);
            }
            else {
                die "invalid 'sprintf' output page format: $outfile"
                    if $pages > 1;
            }

            my $page = $pdf.page($page-num);
            $*ERR.print: "saving page $page-num -> {format.uc} $img-filename...\n"; 
            $.save-as-image($page, $img-filename, :$cache);
        }
    }

    multi method save-as(PDF::Class $pdf, Str(Cool) $outfile where /:i '.pdf' $/) {
        my $page1 = $pdf.page(1);
        my $surface = Cairo::Surface::PDF.create($outfile, $page1.width, $page1.height);
        my UInt $pages = $pdf.page-count;
        my $cache = Cache.new;

        for 1 .. $pages -> UInt $page-num {
            my $content = $pdf.page($page-num);
            PDF::Render::Cairo.render: :$content, :$surface, :$cache;
            $surface.show_page;
        }
        $surface.finish;
     }

}
