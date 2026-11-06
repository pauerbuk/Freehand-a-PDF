#import "FHEngine.h"
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#include <libfreehand/libfreehand.h>
#include <librevenge-stream/librevenge-stream.h>
#include <librevenge/librevenge.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>

@implementation FHConversion
@end

namespace libfreehand { extern bool includeHiddenLayers; }

namespace {

using librevenge::RVNGPropertyList;
using librevenge::RVNGPropertyListVector;
using librevenge::RVNGString;

const double PT = 72.0;  // libfreehand misura in pollici, il PDF in punti

double number(const RVNGPropertyList &p, const char *key, double fallback = 0) {
    return p[key] ? p[key]->getDouble() : fallback;
}
std::string text(const RVNGPropertyList &p, const char *key) {
    return p[key] ? std::string(p[key]->getStr().cstr()) : std::string();
}
CGColorRef newColor(const std::string &hex, double alpha = 1) {
    unsigned v = 0;
    if (hex.size() == 7) sscanf(hex.c_str() + 1, "%x", &v);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat c[4] = {((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0, alpha};
    CGColorRef color = CGColorCreate(space, c);
    CGColorSpaceRelease(space);
    return color;
}

// Scrive il formato testuale di Illustrator (.ai 8), l'unico documentato e con i livelli veri.
class AIWriter {
public:
    double width = 0, height = 0;
    std::string body;
    std::set<std::string> fonts;

    static std::string number(double v) {
        char b[32];
        snprintf(b, sizeof b, "%.4f", v);
        std::string s = b;
        s.erase(s.find_last_not_of('0') + 1);
        if (!s.empty() && s.back() == '.') s.pop_back();
        return s.empty() || s == "-0" ? "0" : s;
    }
    // RGB verso CMYK: i neri e i grigi vanno sul solo nero, come in stampa.
    static std::string cmyk(const std::string &hex, const char *op) {
        unsigned v = 0;
        if (hex.size() == 7) sscanf(hex.c_str() + 1, "%x", &v);
        double r = ((v >> 16) & 255) / 255.0, g = ((v >> 8) & 255) / 255.0, b = (v & 255) / 255.0;
        double c, m, y, k;
        double hi = fmax(r, fmax(g, b)), lo = fmin(r, fmin(g, b));
        if (hi - lo < 0.04) {
            c = m = y = 0;
            k = hi < 0.2 ? 1 : 1 - hi;
        } else {
            k = 1 - hi;
            c = (1 - r - k) / (1 - k); m = (1 - g - k) / (1 - k); y = (1 - b - k) / (1 - k);
        }
        return number(c) + " " + number(m) + " " + number(y) + " " + number(k) + " " + op + "\n";
    }
    static std::string quoted(NSString *text) {
        NSData *bytes = [text dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
        std::string out = "(";
        const uint8_t *p = (const uint8_t *)bytes.bytes;
        for (NSUInteger i = 0; i < bytes.length; ++i) {
            uint8_t c = p[i];
            if (c == '(' || c == ')' || c == '\\') { out += '\\'; out += (char)c; }
            else if (c < 32 || c > 126) { char b[8]; snprintf(b, sizeof b, "\\%03o", c); out += b; }
            else out += (char)c;
        }
        return out + ")";
    }
    void beginLayer(const std::string &name, bool visible) {
        endLayer();
        ++layers;
        std::string v = visible ? "1" : "0";
        body += "%AI5_BeginLayer\n" + v + " 1 1 1 0 0 " + std::to_string(layers % 7) + " 79 128 255 0 50 Lb\n";
        NSString *title = name.empty() ? [NSString stringWithFormat:@"Livello %d", layers] : @(name.c_str());
        body += quoted(title) + " Ln\n0 A\n";
        open = true;
    }
    void ensureLayer() { if (!open) beginLayer("", true); }
    void endLayer() {
        if (open) body += "LB\n%AI5_EndLayer--\n";
        open = false;
    }
    bool write(NSString *path, const std::string &title) {
        endLayer();
        std::string w = number(width), h = number(height), out;
        out += "%!PS-Adobe-3.0 \n%%Creator: Adobe Illustrator(R) 8.0\n%%AI8_CreatorVersion: 8.0.1\n";
        out += "%%For: (FreeHand a PDF) ()\n%%Title: " + title + "\n";
        out += "%%CreationDate: (01/01/2000) (00:00)\n";
        out += "%%BoundingBox: 0 0 " + w + " " + h + "\n%%HiResBoundingBox: 0 0 " + w + " " + h + "\n";
        out += "%%DocumentProcessColors: Cyan Magenta Yellow Black\n%AI5_FileFormat 4.0\n%AI3_ColorUsage: Color\n";
        out += "%AI3_TemplateBox: " + number(width / 2) + " " + number(height / 2) + " " + number(width / 2) + " " + number(height / 2) + "\n";
        out += "%AI3_TileBox: 0 0 " + w + " " + h + "\n%AI3_DocumentPreview: None\n";
        out += "%AI5_ArtSize: " + w + " " + h + "\n%AI5_RulerUnits: 2\n%AI5_ArtFlags: 0 0 0 1 0 0 1 0 0\n";
        out += "%AI5_TargetResolution: 800\n%AI5_NumLayers: " + std::to_string(layers) + "\n%AI5_OpenViewLayers: 7\n";
        out += "%%EndComments\n%%BeginProlog\n%%EndProlog\n%%BeginSetup\n";
        out += "[\n39/quotesingle 96/grave 128/Adieresis/Aring/Ccedilla/Eacute/Ntilde/Odieresis/Udieresis/aacute/agrave/acircumflex/adieresis/atilde/aring/ccedilla/eacute/egrave/ecircumflex/edieresis/iacute/igrave/icircumflex/idieresis/ntilde/oacute/ograve/ocircumflex/odieresis/otilde/uacute/ugrave/ucircumflex/udieresis/dagger/degree/cent/sterling/section/bullet/paragraph/germandbls/registered/copyright/trademark/acute/dieresis/.notdef/AE/Oslash/.notdef/plusminus/.notdef/.notdef/yen/mu/.notdef/.notdef/.notdef/.notdef/.notdef/ordfeminine/ordmasculine/.notdef/ae/oslash/questiondown/exclamdown/logicalnot/.notdef/florin/.notdef/.notdef/guillemotleft/guillemotright/ellipsis/space/Agrave/Atilde/Otilde/OE/oe/endash/emdash/quotedblleft/quotedblright/quoteleft/quoteright/divide/.notdef/ydieresis/Ydieresis/fraction/currency/guilsinglleft/guilsinglright/fi/fl/daggerdbl/periodcentered/quotesinglbase/quotedblbase/perthousand/Acircumflex/Ecircumflex/Aacute/Edieresis/Egrave/Iacute/Icircumflex/Idieresis/Igrave/Oacute/Ocircumflex/.notdef/Ograve/Uacute/Ucircumflex/Ugrave/dotlessi/circumflex/tilde/macron/breve/dotaccent/ring/cedilla/hungarumlaut/ogonek/caron\nTE\n";
        for (const std::string &f : fonts) {
            out += "%AI3_BeginEncoding: _" + f + " " + f + "\n[/_" + f + "/" + f + " 0 0 1 TZ\n%AI3_EndEncoding AdobeType\n";
        }
        out += "%%EndSetup\n1 XR\n";
        out += body;
        out += "%%PageTrailer\ngsave annotatepage grestore showpage\n%%Trailer\n%%EOF\n";
        return [[NSData dataWithBytes:out.data() length:out.size()] writeToFile:path atomically:YES];
    }

private:
    int layers = 0;
    bool open = false;
};

struct Paragraph {
    NSMutableAttributedString *string = [NSMutableAttributedString new];
    std::string align = "left";
    double marginLeft = 0, marginRight = 0, indent = 0, marginTop = 0, marginBottom = 0;
    double lineHeightPt = 0, lineHeightFactor = 0;
    double firstFontSize = 0;
};

class PDFPainter : public librevenge::RVNGDrawingInterface {
public:
    explicit PDFPainter(NSString *path, NSString *keywords = nil, AIWriter *ai = nullptr) : url((__bridge_retained CFURLRef)[NSURL fileURLWithPath:path]), keywords(keywords), ai(ai) {}
    ~PDFPainter() override {
        if (pdf) CGContextRelease(pdf);
        CFRelease(url);
    }
    bool drewPage = false;
    std::set<std::string> fontNotes, warnings;
    std::map<std::string, std::string> substitutions;  // nome originale -> nome PostScript del font usato
    int hiddenLayers = 0;

    void startDocument(const RVNGPropertyList &) override {}
    void endDocument() override {
        if (pdf) CGPDFContextClose(pdf);
    }
    void startLayer(const RVNGPropertyList &p) override {
        if (ai) ai->beginLayer(text(p, "svg:id"), number(p, "freehand:visible", 1) != 0);
    }
    void endLayer() override {
        if (ai) ai->endLayer();
    }
    void startPage(const RVNGPropertyList &p) override {
        double w = number(p, "svg:width") * PT, h = number(p, "svg:height") * PT;
        if (w <= 0 || h <= 0) { w = 595.28; h = 841.89; }
        pageHeight = h;
        drewPage = true;
        if (ai) { ai->width = w; ai->height = h; return; }
        CGRect box = CGRectMake(0, 0, w, h);
        if (!pdf) {
            NSDictionary *info = keywords ? @{(__bridge id)kCGPDFContextKeywords: keywords} : nil;
            pdf = CGPDFContextCreateWithURL(url, &box, (__bridge CFDictionaryRef)info);
        }
        if (!pdf) return;
        CGContextBeginPage(pdf, &box);
        // Stesso verso di FreeHand: l'origine è in alto a sinistra e la y scende.
        CGContextTranslateCTM(pdf, 0, h);
        CGContextScaleCTM(pdf, 1, -1);
        drewPage = true;
    }
    void endPage() override {
        if (pdf) CGContextEndPage(pdf);
    }
    void setStyle(const RVNGPropertyList &p) override { style = p; }

    void openGroup(const RVNGPropertyList &p) override {
        const RVNGPropertyListVector *clip = p.child("svg:d");
        groups.push_back(clip != nullptr);
        if (ai) {
            ai->ensureLayer();
            if (!clip) { ai->body += "u\n"; return; }
            CGPathRef mask = newPath(*clip);
            ai->body += "q\n";
            if (text(p, "svg:fill-rule") == "evenodd") ai->body += "1 D\n";
            for (const AISubpath &sub : subpaths(mask)) ai->body += sub.ops + "h\n";
            ai->body += "W\nn\n";
            CGPathRelease(mask);
            return;
        }
        if (!clip || !pdf) return;
        CGPathRef path = newPath(*clip);
        CGContextSaveGState(pdf);
        CGContextAddPath(pdf, path);
        if (text(p, "svg:fill-rule") == "evenodd") CGContextEOClip(pdf); else CGContextClip(pdf);
        CGPathRelease(path);
    }
    void closeGroup() override {
        if (groups.empty()) return;
        if (ai) ai->body += groups.back() ? "Q\n" : "U\n";
        if (groups.back() && pdf) CGContextRestoreGState(pdf);
        groups.pop_back();
    }

    void drawPath(const RVNGPropertyList &p) override {
        const RVNGPropertyListVector *d = p.child("svg:d");
        if (!d || (!pdf && !ai)) return;
        CGPathRef path = newPath(*d);
        paint(path, *d);
        CGPathRelease(path);
    }
    void drawRectangle(const RVNGPropertyList &p) override {
        if (!pdf && !ai) return;
        CGPathRef path = CGPathCreateWithRect(CGRectMake(number(p, "svg:x") * PT, number(p, "svg:y") * PT, number(p, "svg:width") * PT, number(p, "svg:height") * PT), nullptr);
        paint(path, RVNGPropertyListVector());
        CGPathRelease(path);
    }
    void drawEllipse(const RVNGPropertyList &p) override {
        if (!pdf && !ai) return;
        double rx = number(p, "svg:rx") * PT, ry = number(p, "svg:ry") * PT;
        CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(number(p, "svg:cx") * PT - rx, number(p, "svg:cy") * PT - ry, 2 * rx, 2 * ry), nullptr);
        paint(path, RVNGPropertyListVector());
        CGPathRelease(path);
    }
    void drawPolygon(const RVNGPropertyList &p) override { polyline(p, true); }
    void drawPolyline(const RVNGPropertyList &p) override { polyline(p, false); }
    void drawGraphicObject(const RVNGPropertyList &p) override {
        if (ai) { warnings.insert("Le immagini incorporate non sono incluse nel file .ai."); return; }
        if (!pdf) return;
        CGImageRef image = p["office:binary-data"] ? newImage(p["office:binary-data"]->getStr()) : nullptr;
        if (!image) { warnings.insert("Immagine incorporata non leggibile: è stata omessa."); return; }
        double x = number(p, "svg:x") * PT, y = number(p, "svg:y") * PT, w = number(p, "svg:width") * PT, h = number(p, "svg:height") * PT;
        CGContextSaveGState(pdf);
        CGContextTranslateCTM(pdf, x + w / 2, y + h / 2);
        CGContextRotateCTM(pdf, number(p, "librevenge:rotate") * M_PI / 180);
        CGContextScaleCTM(pdf, 1, -1);
        CGContextDrawImage(pdf, CGRectMake(-w / 2, -h / 2, w, h), image);
        CGContextRestoreGState(pdf);
        CGImageRelease(image);
    }

    void startTextObject(const RVNGPropertyList &p) override {
        frame = p;
        paragraphs.clear();
    }
    void endTextObject() override { drawText(); paragraphs.clear(); }
    void openParagraph(const RVNGPropertyList &p) override {
        Paragraph para;
        std::string align = text(p, "fo:text-align");
        if (!align.empty()) para.align = align;
        para.marginLeft = number(p, "fo:margin-left");
        para.marginRight = number(p, "fo:margin-right");
        para.indent = number(p, "fo:text-indent");
        para.marginTop = number(p, "fo:margin-top");
        para.marginBottom = number(p, "fo:margin-bottom");
        if (p["fo:line-height"]) {
            if (p["fo:line-height"]->getUnit() == librevenge::RVNG_PERCENT) para.lineHeightFactor = p["fo:line-height"]->getDouble();
            else para.lineHeightPt = p["fo:line-height"]->getDouble();
        }
        paragraphs.push_back(para);
    }
    void closeParagraph() override {}
    void openSpan(const RVNGPropertyList &p) override { span = p; }
    void closeSpan() override {}
    void insertText(const RVNGString &s) override { append(@(s.cstr())); }
    void insertTab() override { append(@"\t"); }
    void insertSpace() override { append(@" "); }
    void insertLineBreak() override { append(@" "); }

    // Una riga di testo del vecchio formato: posizione della linea di base e matrice in punti, y verso l'alto.
    void drawPlacedText(NSString *string, const std::string &fontName, double size, const std::string &color,
                        double storedWidth, CGPoint origin, CGAffineTransform matrix, double pageHeight) {
        if ((!pdf && !ai) || string.length == 0) return;
        NSFont *font = resolveFont(fontName, size, false, false);
        CGColorRef ink = newColor(color);
        NSDictionary *attrs = @{(__bridge id)kCTFontAttributeName: (__bridge id)(__bridge CTFontRef)font, (__bridge id)kCTForegroundColorAttributeName: (__bridge id)ink,
                                @"FHFont": @(aiFontName(fontName, font).c_str()), @"FHColor": @(color.c_str()), @"FHSize": @(size)};
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:string attributes:attrs]);
        double width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
        double fit = (storedWidth > 0 && width > 0) ? storedWidth / width : 1;
        if (ai) {
            CGAffineTransform m = CGAffineTransformScale(matrix, fit, 1);
            m.tx = origin.x; m.ty = origin.y;
            writeAIText(string, attrs, line, m);
            CFRelease(line);
            CGColorRelease(ink);
            return;
        }
        CGContextSaveGState(pdf);
        CGContextTranslateCTM(pdf, origin.x, pageHeight - origin.y);
        CGContextScaleCTM(pdf, 1, -1);
        CGContextConcatCTM(pdf, matrix);
        CGContextScaleCTM(pdf, fit, 1);
        CGContextSetTextMatrix(pdf, CGAffineTransformIdentity);
        CGContextSetTextPosition(pdf, 0, 0);
        CTLineDraw(line, pdf);
        CGContextRestoreGState(pdf);
        CFRelease(line);
        CGColorRelease(ink);
    }

    // Non usati da libfreehand o senza effetto sul disegno.
    void setDocumentMetaData(const RVNGPropertyList &p) override {
        hiddenLayers = p["freehand:hidden-layers"] ? p["freehand:hidden-layers"]->getInt() : 0;
        bool included = libfreehand::includeHiddenLayers;
        if (hiddenLayers == 1) warnings.insert(included ? "Incluso un livello che in FreeHand era nascosto." : "Un livello nascosto in FreeHand non è incluso nel PDF.");
        else if (hiddenLayers > 1) warnings.insert(included ? "Inclusi " + std::to_string(hiddenLayers) + " livelli che in FreeHand erano nascosti." : std::to_string(hiddenLayers) + " livelli nascosti in FreeHand non sono inclusi nel PDF.");
    }
    void defineEmbeddedFont(const RVNGPropertyList &) override {}
    void startMasterPage(const RVNGPropertyList &) override {}
    void endMasterPage() override {}
    void startEmbeddedGraphics(const RVNGPropertyList &) override {}
    void endEmbeddedGraphics() override {}
    void drawConnector(const RVNGPropertyList &) override {}
    void startTableObject(const RVNGPropertyList &) override {}
    void openTableRow(const RVNGPropertyList &) override {}
    void closeTableRow() override {}
    void openTableCell(const RVNGPropertyList &) override {}
    void closeTableCell() override {}
    void insertCoveredTableCell(const RVNGPropertyList &) override {}
    void endTableObject() override {}
    void insertField(const RVNGPropertyList &) override {}
    void openOrderedListLevel(const RVNGPropertyList &) override {}
    void openUnorderedListLevel(const RVNGPropertyList &) override {}
    void closeOrderedListLevel() override {}
    void closeUnorderedListLevel() override {}
    void openListElement(const RVNGPropertyList &) override {}
    void closeListElement() override {}
    void defineParagraphStyle(const RVNGPropertyList &) override {}
    void defineCharacterStyle(const RVNGPropertyList &) override {}
    void openLink(const RVNGPropertyList &) override {}
    void closeLink() override {}

private:
    CFURLRef url;
    NSString *keywords;
    AIWriter *ai;
    double pageHeight = 0;
    CGContextRef pdf = nullptr;

    struct AISubpath { std::string ops; bool closed = false; };

    std::vector<AISubpath> subpaths(CGPathRef path) {
        __block std::vector<AISubpath> list;
        __block CGPoint current = CGPointZero;
        double h = pageHeight;
        CGPathApplyWithBlock(path, ^(const CGPathElement *e) {
            auto P = [&](CGPoint p) { return AIWriter::number(p.x) + " " + AIWriter::number(h - p.y) + " "; };
            switch (e->type) {
                case kCGPathElementMoveToPoint:
                    list.push_back(AISubpath());
                    list.back().ops += P(e->points[0]) + "m\n";
                    current = e->points[0];
                    break;
                case kCGPathElementAddLineToPoint:
                    if (list.empty()) break;
                    list.back().ops += P(e->points[0]) + "l\n";
                    current = e->points[0];
                    break;
                case kCGPathElementAddCurveToPoint:
                    if (list.empty()) break;
                    list.back().ops += P(e->points[0]) + P(e->points[1]) + P(e->points[2]) + "c\n";
                    current = e->points[2];
                    break;
                case kCGPathElementAddQuadCurveToPoint: {
                    if (list.empty()) break;
                    CGPoint a = current, q = e->points[0], b = e->points[1];
                    CGPoint c1 = CGPointMake(a.x + 2.0 / 3 * (q.x - a.x), a.y + 2.0 / 3 * (q.y - a.y));
                    CGPoint c2 = CGPointMake(b.x + 2.0 / 3 * (q.x - b.x), b.y + 2.0 / 3 * (q.y - b.y));
                    list.back().ops += P(c1) + P(c2) + P(b) + "c\n";
                    current = b;
                    break;
                }
                case kCGPathElementCloseSubpath:
                    if (!list.empty()) list.back().closed = true;
                    break;
            }
        });
        return list;
    }

    void paintAI(CGPathRef path) {
        std::vector<AISubpath> parts = subpaths(path);
        if (parts.empty()) return;
        ai->ensureLayer();
        std::string fill = text(style, "draw:fill"), stroke = text(style, "draw:stroke");
        bool fills = !fill.empty() && fill != "none", strokes = !stroke.empty() && stroke != "none";
        std::string &out = ai->body;
        if (fills) {
            std::string color = text(style, "draw:fill-color");
            if (fill == "gradient") {
                color = text(style, "draw:end-color");
                warnings.insert("Le sfumature sono diventate colori pieni nel file .ai.");
            } else if (fill == "bitmap") {
                color = "#d9d9d9";
                warnings.insert("I riempimenti a immagine sono diventati grigi nel file .ai.");
            }
            out += AIWriter::cmyk(color, "k");
        }
        if (style["draw:opacity"] || style["svg:stroke-opacity"]) warnings.insert("Le trasparenze non sono riprodotte nel file .ai.");
        if (strokes) {
            double width = number(style, "svg:stroke-width") * PT;
            out += AIWriter::cmyk(text(style, "svg:stroke-color"), "K");
            out += AIWriter::number(width > 0 ? width : 0.25) + " w\n";
            out += AIWriter::number(number(style, "svg:stroke-miterlimit", 3.864)) + " M\n";
            if (stroke == "dash") {
                double gap = dashLength("draw:distance", width, width);
                out += "[";
                for (int i = 0, n = (int)number(style, "draw:dots1", 0); i < n; ++i) out += AIWriter::number(dashLength("draw:dots1-length", width, width)) + " " + AIWriter::number(gap) + " ";
                for (int i = 0, n = (int)number(style, "draw:dots2", 0); i < n; ++i) out += AIWriter::number(dashLength("draw:dots2-length", width, width)) + " " + AIWriter::number(gap) + " ";
                out += "] 0 d\n";
            } else {
                out += "[] 0 d\n";
            }
            if (style["draw:marker-start-path"] || style["draw:marker-end-path"]) warnings.insert("Le punte di freccia non sono incluse nel file .ai.");
        }
        out += text(style, "svg:fill-rule") == "evenodd" ? "1 D\n" : "0 D\n";
        bool compound = parts.size() > 1;
        if (compound) out += "*u\n";
        for (const AISubpath &part : parts) {
            out += part.ops;
            if (fills && strokes) out += part.closed ? "b\n" : "B\n";
            else if (fills) out += part.closed ? "f\n" : "F\n";
            else if (strokes) out += part.closed ? "s\n" : "S\n";
            else out += part.closed ? "n\n" : "N\n";
        }
        if (compound) out += "*U\n";
    }

    std::string aiFontName(const std::string &requested, NSFont *font) {
        std::string name = substitutions.count(requested) ? requested : std::string(font.fontName.UTF8String), clean;
        for (char c : name) if (isalnum((unsigned char)c) || c == '-' || c == '_') clean += c;
        return clean.empty() ? "Helvetica" : clean;
    }

    // Una riga di testo, in punti con la y verso l'alto: resta testo modificabile, con il nome del font originale.
    void writeAIText(NSString *string, NSDictionary *only, CTLineRef line, CGAffineTransform m) {
        ai->ensureLayer();
        std::string &out = ai->body;
        out += "0 To\n";
        out += AIWriter::number(m.a) + " " + AIWriter::number(m.b) + " " + AIWriter::number(m.c) + " " + AIWriter::number(m.d) + " " + AIWriter::number(m.tx) + " " + AIWriter::number(m.ty) + " 0 Tp\nTP\n0 Tr\n";
        for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
            CTRunRef run = (__bridge CTRunRef)object;
            CFRange range = CTRunGetStringRange(run);
            NSDictionary *attrs = only ?: (__bridge NSDictionary *)CTRunGetAttributes(run);
            NSString *font = attrs[@"FHFont"] ?: @"Helvetica";
            double size = [attrs[@"FHSize"] doubleValue];
            double scale = attrs[@"FHScale"] ? [attrs[@"FHScale"] doubleValue] : 1;
            double kern = [attrs[(__bridge id)kCTKernAttributeName] doubleValue];
            NSString *hex = attrs[@"FHColor"] ?: @"#000000";
            ai->fonts.insert(font.UTF8String);
            out += AIWriter::cmyk(hex.UTF8String, "k");
            out += "/_" + std::string(font.UTF8String) + " " + AIWriter::number(size) + " Tf\n";
            out += "0 Ts " + AIWriter::number(scale * 100) + " Tz " + AIWriter::number(size > 0 ? kern / size * 1000 : 0) + " Tt\n";
            NSString *piece = [[string substringWithRange:NSMakeRange(range.location, range.length)] stringByReplacingOccurrencesOfString:@"\u2028" withString:@" "];
            out += AIWriter::quoted(piece) + " Tx\n";
        }
        out += "(\\r) TX\nTO\n";
    }
    RVNGPropertyList style, frame, span;
    std::vector<bool> groups;
    std::vector<Paragraph> paragraphs;

    CGPathRef newPath(const RVNGPropertyListVector &d) {
        CGMutablePathRef path = CGPathCreateMutable();
        for (unsigned long i = 0; i < d.count(); ++i) {
            const RVNGPropertyList &e = d[i];
            std::string a = text(e, "librevenge:path-action");
            double x = number(e, "svg:x") * PT, y = number(e, "svg:y") * PT;
            if (a == "M") CGPathMoveToPoint(path, nullptr, x, y);
            else if (CGPathIsEmpty(path)) continue;
            else if (a == "L") CGPathAddLineToPoint(path, nullptr, x, y);
            else if (a == "C") CGPathAddCurveToPoint(path, nullptr, number(e, "svg:x1") * PT, number(e, "svg:y1") * PT, number(e, "svg:x2") * PT, number(e, "svg:y2") * PT, x, y);
            else if (a == "Q") CGPathAddQuadCurveToPoint(path, nullptr, number(e, "svg:x1") * PT, number(e, "svg:y1") * PT, x, y);
            else if (a == "Z") CGPathCloseSubpath(path);
            else if (a == "A") CGPathAddLineToPoint(path, nullptr, x, y);
        }
        return path;
    }

    void polyline(const RVNGPropertyList &p, bool closed) {
        const RVNGPropertyListVector *points = p.child("svg:points");
        if (!points || !points->count() || (!pdf && !ai)) return;
        CGMutablePathRef path = CGPathCreateMutable();
        for (unsigned long i = 0; i < points->count(); ++i) {
            double x = number((*points)[i], "svg:x") * PT, y = number((*points)[i], "svg:y") * PT;
            if (i == 0) CGPathMoveToPoint(path, nullptr, x, y); else CGPathAddLineToPoint(path, nullptr, x, y);
        }
        if (closed) CGPathCloseSubpath(path);
        paint(path, RVNGPropertyListVector());
        CGPathRelease(path);
    }

    void paint(CGPathRef path, const RVNGPropertyListVector &d) {
        if (ai) { paintAI(path); return; }
        if (text(style, "draw:shadow") == "visible") paintShadow(path);
        paintFill(path);
        paintStroke(path, d);
    }

    void paintShadow(CGPathRef path) {
        std::string fill = text(style, "draw:fill"), stroke = text(style, "draw:stroke");
        if ((fill.empty() || fill == "none") && (stroke.empty() || stroke == "none")) return;
        CGColorRef color = newColor(text(style, "draw:shadow-color"), number(style, "draw:shadow-opacity", 1));
        CGContextSaveGState(pdf);
        CGContextTranslateCTM(pdf, number(style, "draw:shadow-offset-x") * PT, number(style, "draw:shadow-offset-y") * PT);
        CGContextAddPath(pdf, path);
        CGContextSetFillColorWithColor(pdf, color);
        CGContextFillPath(pdf);
        CGContextRestoreGState(pdf);
        CGColorRelease(color);
        warnings.insert("Ombre riprodotte senza sfumatura.");
    }

    void addAndClip(CGPathRef path, bool evenOdd) {
        CGContextAddPath(pdf, path);
        if (evenOdd) CGContextEOClip(pdf); else CGContextClip(pdf);
    }

    void paintFill(CGPathRef path) {
        std::string fill = text(style, "draw:fill");
        if (fill.empty() || fill == "none") return;
        bool evenOdd = text(style, "svg:fill-rule") == "evenodd";
        double opacity = number(style, "draw:opacity", 1);
        CGContextSaveGState(pdf);
        CGContextSetAlpha(pdf, opacity);
        if (fill == "solid") {
            CGColorRef color = newColor(text(style, "draw:fill-color"));
            CGContextSetFillColorWithColor(pdf, color);
            CGContextAddPath(pdf, path);
            if (evenOdd) CGContextEOFillPath(pdf); else CGContextFillPath(pdf);
            CGColorRelease(color);
        } else if (fill == "gradient") {
            paintGradient(path, evenOdd);
        } else if (fill == "bitmap") {
            paintBitmap(path, evenOdd);
        }
        CGContextRestoreGState(pdf);
    }

    void paintGradient(CGPathRef path, bool evenOdd) {
        CGRect box = CGPathGetPathBoundingBox(path);
        if (CGRectIsEmpty(box)) return;
        bool radial = text(style, "draw:style") == "radial";
        std::string start = text(style, "draw:start-color"), end = text(style, "draw:end-color");
        CGColorRef first = newColor(radial ? end : start), second = newColor(radial ? start : end);
        const void *colors[] = {first, second};
        CFArrayRef array = CFArrayCreate(nullptr, colors, 2, &kCFTypeArrayCallBacks);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGGradientRef gradient = CGGradientCreateWithColors(space, array, nullptr);
        addAndClip(path, evenOdd);
        // Le coordinate del gradiente sono relative al riquadro della forma, come in SVG.
        CGContextTranslateCTM(pdf, box.origin.x, box.origin.y);
        CGContextScaleCTM(pdf, box.size.width, box.size.height);
        CGGradientDrawingOptions extend = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;
        if (radial) {
            CGPoint c = CGPointMake(number(style, "svg:cx", 0.5), number(style, "svg:cy", 0.5));
            CGContextDrawRadialGradient(pdf, gradient, c, 0, c, 1, extend);
        } else {
            CGContextTranslateCTM(pdf, 0.5, 0.5);
            CGContextRotateCTM(pdf, -number(style, "draw:angle") * M_PI / 180);
            CGContextTranslateCTM(pdf, -0.5, -0.5);
            CGContextDrawLinearGradient(pdf, gradient, CGPointMake(0, 0), CGPointMake(0, 1), extend);
        }
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        CFRelease(array);
        CGColorRelease(first);
        CGColorRelease(second);
    }

    void paintBitmap(CGPathRef path, bool evenOdd) {
        addAndClip(path, evenOdd);
        CGRect box = CGPathGetPathBoundingBox(path);
        if (text(style, "librevenge:mime-type") == "image/svg+xml" || !style["draw:fill-image"]) {
            warnings.insert("Riempimenti a mosaico sostituiti da un grigio chiaro.");
            CGContextSetGrayFillColor(pdf, 0.85, 1);
            CGContextFillRect(pdf, box);
            return;
        }
        CGImageRef image = newImage(style["draw:fill-image"]->getStr());
        if (!image) { warnings.insert("Riempimento a immagine non leggibile: è stato omesso."); return; }
        double w = number(style, "draw:fill-image-width") * PT, h = number(style, "draw:fill-image-height") * PT;
        if (w <= 0) w = CGImageGetWidth(image);
        if (h <= 0) h = CGImageGetHeight(image);
        CGContextTranslateCTM(pdf, box.origin.x, box.origin.y);
        CGContextScaleCTM(pdf, 1, -1);
        for (double y = 0; y < box.size.height; y += h)
            for (double x = 0; x < box.size.width; x += w)
                CGContextDrawImage(pdf, CGRectMake(x, -y - h, w, h), image);
        CGImageRelease(image);
    }

    CGImageRef newImage(const RVNGString &base64) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:@(base64.cstr()) options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!data) return nullptr;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        if (!source) return nullptr;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
        CFRelease(source);
        return image;
    }

    void paintStroke(CGPathRef path, const RVNGPropertyListVector &d) {
        std::string stroke = text(style, "draw:stroke");
        if (stroke.empty() || stroke == "none") return;
        double width = number(style, "svg:stroke-width") * PT;
        if (width <= 0) width = 0.25;
        CGColorRef color = newColor(text(style, "svg:stroke-color"));
        CGContextSaveGState(pdf);
        CGContextSetAlpha(pdf, number(style, "svg:stroke-opacity", 1));
        CGContextSetStrokeColorWithColor(pdf, color);
        CGContextSetFillColorWithColor(pdf, color);
        CGContextSetLineWidth(pdf, width);
        std::string cap = text(style, "svg:stroke-linecap"), join = text(style, "svg:stroke-linejoin");
        CGContextSetLineCap(pdf, cap == "round" ? kCGLineCapRound : cap == "square" ? kCGLineCapSquare : kCGLineCapButt);
        CGContextSetLineJoin(pdf, join == "round" ? kCGLineJoinRound : join == "bevel" ? kCGLineJoinBevel : kCGLineJoinMiter);
        CGContextSetMiterLimit(pdf, number(style, "svg:stroke-miterlimit", 3.864));
        if (stroke == "dash") setDash(width);
        CGContextAddPath(pdf, path);
        CGContextStrokePath(pdf);
        CGContextSetLineDash(pdf, 0, nullptr, 0);
        if (style["draw:marker-start-path"]) drawArrow(d, true, width);
        if (style["draw:marker-end-path"]) drawArrow(d, false, width);
        CGContextRestoreGState(pdf);
        CGColorRelease(color);
    }

    double dashLength(const char *key, double width, double fallback) {
        if (!style[key]) return fallback;
        return style[key]->getUnit() == librevenge::RVNG_PERCENT ? style[key]->getDouble() * width : style[key]->getDouble() * PT;
    }
    void setDash(double width) {
        std::vector<CGFloat> pattern;
        double gap = dashLength("draw:distance", width, width);
        for (int i = 0, n = (int)number(style, "draw:dots1", 0); i < n; ++i) {
            pattern.push_back(dashLength("draw:dots1-length", width, width));
            pattern.push_back(gap);
        }
        for (int i = 0, n = (int)number(style, "draw:dots2", 0); i < n; ++i) {
            pattern.push_back(dashLength("draw:dots2-length", width, width));
            pattern.push_back(gap);
        }
        if (!pattern.empty()) CGContextSetLineDash(pdf, 0, pattern.data(), pattern.size());
    }

    // Una punta generica a triangolo orientata come l'estremità della linea.
    void drawArrow(const RVNGPropertyListVector &d, bool atStart, double width) {
        if (d.count() < 2) return;
        CGPoint tip, from;
        if (atStart) {
            tip = CGPointMake(number(d[0], "svg:x") * PT, number(d[0], "svg:y") * PT);
            const RVNGPropertyList &n = d[1];
            bool curve = n["svg:x1"];
            from = CGPointMake(number(n, curve ? "svg:x1" : "svg:x") * PT, number(n, curve ? "svg:y1" : "svg:y") * PT);
        } else {
            unsigned long last = d.count() - 1;
            const RVNGPropertyList &e = d[last];
            if (text(e, "librevenge:path-action") == "Z") return;
            tip = CGPointMake(number(e, "svg:x") * PT, number(e, "svg:y") * PT);
            bool curve = e["svg:x2"];
            from = CGPointMake(number(curve ? e : d[last - 1], curve ? "svg:x2" : "svg:x") * PT, number(curve ? e : d[last - 1], curve ? "svg:y2" : "svg:y") * PT);
        }
        double angle = atan2(tip.y - from.y, tip.x - from.x), size = fmax(width * 5, 3);
        CGContextSaveGState(pdf);
        CGContextTranslateCTM(pdf, tip.x, tip.y);
        CGContextRotateCTM(pdf, angle);
        CGContextMoveToPoint(pdf, 0, 0);
        CGContextAddLineToPoint(pdf, -size, size * 0.4);
        CGContextAddLineToPoint(pdf, -size, -size * 0.4);
        CGContextClosePath(pdf);
        CGContextFillPath(pdf);
        CGContextRestoreGState(pdf);
        warnings.insert("Punte di freccia ridisegnate con una forma generica.");
    }

    NSFont *resolveFont(const std::string &requested, double size, bool bold, bool italic) {
        NSString *name = requested.empty() ? @"Helvetica" : @(requested.c_str());
        NSFontManager *fm = NSFontManager.sharedFontManager;
        NSFontTraitMask traits = (bold ? NSBoldFontMask : 0) | (italic ? NSItalicFontMask : 0);
        NSFont *font = [fm fontWithFamily:name traits:traits weight:(bold ? 9 : 5) size:size];
        if (!font) font = [NSFont fontWithName:name size:size];
        if (font) return font;

        // "Helvetica 55 Roman" o "Univers 67 CondensedBold": prova la famiglia senza il codice di peso.
        NSString *lower = name.lowercaseString;
        for (NSString *prefix in @[@"B ", @"I ", @"BI ", @"IB "]) {
            if (![name hasPrefix:prefix]) continue;
            NSString *family = [name substringFromIndex:prefix.length];
            for (NSString *word in @[@" Bold", @" Italic", @" Oblique"]) family = [family stringByReplacingOccurrencesOfString:word withString:@""];
            NSFontTraitMask style = 0;
            if ([prefix containsString:@"B"] || [lower containsString:@"bold"]) style |= NSBoldFontMask;
            if ([prefix containsString:@"I"] || [lower containsString:@"italic"]) style |= NSItalicFontMask;
            font = [fm fontWithFamily:family traits:style weight:((style & NSBoldFontMask) ? 9 : 5) size:size];
            if (font) return font;
        }
        if ([lower containsString:@"bold"] || [lower containsString:@"black"] || [lower containsString:@"heavy"]) traits |= NSBoldFontMask;
        if ([lower containsString:@"italic"] || [lower containsString:@"oblique"]) traits |= NSItalicFontMask;
        NSUInteger cut = [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789-"]].location;
        if (cut != NSNotFound && cut > 0) {
            NSString *family = [[name substringToIndex:cut] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            font = [fm fontWithFamily:family traits:traits weight:((traits & NSBoldFontMask) ? 9 : 5) size:size];
        }
        if (!font) font = [fm fontWithFamily:@"Helvetica" traits:traits weight:((traits & NSBoldFontMask) ? 9 : 5) size:size];
        if (!font) font = [NSFont systemFontOfSize:size];
        fontNotes.insert(requested + " → " + std::string(font.displayName.UTF8String));
        substitutions[requested] = font.fontName.UTF8String;
        return font;
    }

    void append(NSString *s) {
        if (!s || paragraphs.empty()) return;
        double size = number(span, "fo:font-size", 12);
        if (size <= 0) size = 12;
        bool bold = text(span, "fo:font-weight") == "bold", italic = text(span, "fo:font-style") == "italic";
        NSFont *font = resolveFont(text(span, "style:font-name"), size, bold, italic);
        CTFontRef ctFont = (__bridge CTFontRef)font;
        CTFontRef scaled = nullptr;
        double scale = number(span, "style:text-scale", 1);
        if (scale > 0 && fabs(scale - 1) > 0.001) {
            CGAffineTransform m = CGAffineTransformMakeScale(scale, 1);
            scaled = CTFontCreateCopyWithAttributes(ctFont, size, &m, nullptr);
            ctFont = scaled;
        }
        CGColorRef color = newColor(span["fo:color"] ? text(span, "fo:color") : "#000000");
        std::string colorName = span["fo:color"] ? text(span, "fo:color") : "#000000";
        NSMutableDictionary *attrs = [@{(__bridge id)kCTFontAttributeName: (__bridge id)ctFont, (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color,
                                        @"FHFont": @(aiFontName(text(span, "style:font-name"), font).c_str()), @"FHColor": @(colorName.c_str()), @"FHSize": @(size), @"FHScale": @(scale)} mutableCopy];
        if (span["fo:letter-spacing"]) attrs[(__bridge id)kCTKernAttributeName] = @(span["fo:letter-spacing"]->getDouble());
        if (text(span, "style:text-outline") == "true") attrs[(__bridge id)kCTStrokeWidthAttributeName] = @3;
        if (!text(span, "style:text-position").empty()) attrs[(__bridge id)kCTBaselineOffsetAttributeName] = @(atof(text(span, "style:text-position").c_str()) / 100 * size);
        if (span["style:text-underline-type"] && text(span, "style:text-underline-type") != "none") attrs[(__bridge id)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
        Paragraph &para = paragraphs.back();
        if (para.firstFontSize == 0) para.firstFontSize = size;
        [para.string appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:attrs]];
        CGColorRelease(color);
        if (scaled) CFRelease(scaled);
    }

    struct Line {
        CTLineRef line;
        double width, ascent, descent, natural, left, top = 0;
        const Paragraph *para;
        bool lastOfParagraph;
    };

    void drawText() {
        if (!pdf && !ai) return;
        double x = number(frame, "svg:x") * PT, y = number(frame, "svg:y") * PT;
        double w = number(frame, "svg:width") * PT, h = number(frame, "svg:height") * PT;
        double rotate = number(frame, "librevenge:rotate");
        if (frame["librevenge:rotate-cx"] && frame["librevenge:rotate-cy"]) {
            x = number(frame, "librevenge:rotate-cx") * PT - w / 2;
            y = number(frame, "librevenge:rotate-cy") * PT - h / 2;
        }

        std::vector<Line> lines;
        bool explicitHeight = false, hasMargins = false;
        for (const Paragraph &para : paragraphs) {
            if (para.lineHeightPt > 0 || para.lineHeightFactor > 0) explicitHeight = true;
            if (para.marginTop != 0 || para.marginBottom != 0) hasMargins = true;
            if (para.string.length == 0) {
                double size = para.firstFontSize > 0 ? para.firstFontSize : 12;
                lines.push_back({nullptr, 0, size * 0.8, size * 0.2, size * 1.2, para.marginLeft, 0, &para, true});
                continue;
            }
            CTTypesetterRef setter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)para.string);
            double avail = w - para.marginLeft - para.marginRight;
            CFIndex start = 0, length = para.string.length;
            // I font del Mac sono spesso un po' più larghi di quelli di allora: una riga che in FreeHand
            // stava tutta non deve andare a capo per pochi punti. I paragrafi lunghi restano nel riquadro.
            CTLineRef whole = CTTypesetterCreateLine(setter, CFRangeMake(0, length));
            bool fitsOneLine = CTLineGetTypographicBounds(whole, nullptr, nullptr, nullptr) <= (avail - para.indent) * 1.08
                && [para.string.string rangeOfString:@"\u2028"].location == NSNotFound;
            CFRelease(whole);
            bool first = true;
            while (start < length) {
                double room = avail - (first ? para.indent : 0);
                double breakWidth = (w > 0 && room > 0 && !fitsOneLine) ? room : 1e7;
                CFIndex count = CTTypesetterSuggestLineBreak(setter, start, breakWidth);
                if (count <= 0) count = length - start;
                CTLineRef line = CTTypesetterCreateLine(setter, CFRangeMake(start, count));
                CGFloat ascent = 0, descent = 0, leading = 0;
                double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading) - CTLineGetTrailingWhitespaceWidth(line);
                bool last = start + count >= length;
                if (para.align == "justify" && !last && width < room) {
                    CTLineRef justified = CTLineCreateJustifiedLine(line, 1.0, room);
                    if (justified) { CFRelease(line); line = justified; width = room; }
                }
                double left = para.marginLeft + (first ? para.indent : 0);
                if (para.align == "center") left += (room - width) / 2;
                else if (para.align == "end" || para.align == "right") left += room - width;
                lines.push_back({line, width, ascent, descent, ascent + descent + leading, left, 0, &para, last});
                start += count;
                first = false;
            }
            CFRelease(setter);
        }
        if (lines.empty()) return;

        // FreeHand salva l'altezza esatta del riquadro: se le righe sono regolari, è l'interlinea originale.
        double fromFrame = 0;
        if (!explicitHeight && !hasMargins && h > 0) {
            double candidate = h / lines.size(), reference = lines[0].ascent + lines[0].descent;
            if (candidate > reference * 0.7 && candidate < reference * 1.35) fromFrame = candidate;
        }

        if (pdf) CGContextSaveGState(pdf);
        if (pdf && rotate != 0) {
            CGContextTranslateCTM(pdf, x + w / 2, y + h / 2);
            CGContextRotateCTM(pdf, rotate * M_PI / 180);
            CGContextTranslateCTM(pdf, -(x + w / 2), -(y + h / 2));
        }
        double cursor = y;
        const Paragraph *previous = nullptr;
        for (Line &l : lines) {
            if (l.para != previous) { cursor += l.para->marginTop; previous = l.para; }
            double height = l.para->lineHeightPt > 0 ? l.para->lineHeightPt
                          : l.para->lineHeightFactor > 0 ? l.natural * l.para->lineHeightFactor
                          : fromFrame > 0 ? fromFrame : l.natural;
            double baseline = cursor + (height - (l.ascent + l.descent)) / 2 + l.ascent;
            if (l.line && ai) {
                // Nel formato .ai la y sale: la rotazione oraria della pagina resta oraria.
                double angle = -rotate * M_PI / 180, cx = x + w / 2, cy = pageHeight - (y + h / 2);
                double px = x + l.left - cx, py = pageHeight - baseline - cy;
                CGAffineTransform m = CGAffineTransformMake(cos(angle), sin(angle), -sin(angle), cos(angle), cx + px * cos(angle) - py * sin(angle), cy + px * sin(angle) + py * cos(angle));
                writeAIText(l.para->string.string, nil, l.line, m);
                CFRelease(l.line);
            } else if (l.line) {
                CGContextSaveGState(pdf);
                CGContextTranslateCTM(pdf, x + l.left, baseline);
                CGContextScaleCTM(pdf, 1, -1);
                CGContextSetTextMatrix(pdf, CGAffineTransformIdentity);
                CGContextSetTextPosition(pdf, 0, 0);
                CTLineDraw(l.line, pdf);
                CGContextRestoreGState(pdf);
                CFRelease(l.line);
            }
            cursor += height;
            if (l.lastOfParagraph) cursor += l.para->marginBottom;
        }
        if (pdf) CGContextRestoreGState(pdf);
    }
};

// Formato FHD2 (FreeHand dei primi anni '90), che libfreehand non legge. Decifrato da un file reale:
// una sequenza di record numerati, ciascuno con dimensione in memoria (u32), tipo (u16) e dati big-endian.
// Le coordinate sono in decimi di punto con la y verso l'alto.
class OldFreeHand {
public:
    explicit OldFreeHand(NSData *data) : d((const uint8_t *)data.bytes), size(data.length) {}

    static bool matches(NSData *data) {
        return data.length >= 4 && memcmp(data.bytes, "FHD", 3) == 0 && ((const uint8_t *)data.bytes)[3] <= '3';
    }

    bool draw(PDFPainter &painter, std::set<std::string> &warnings) {
        if (!walk()) return false;
        CGRect box = bounds();
        if (CGRectIsNull(box) || CGRectIsEmpty(box)) return false;
        // Le dimensioni della pagina non sono ancora decifrate: A4 se il disegno ci sta, altrimenti su misura.
        double pageWidth, pageHeight, shiftX = 0, shiftY = 0;
        if (box.origin.x >= 0 && box.origin.y >= 0 && CGRectGetMaxX(box) <= 841.89 && CGRectGetMaxY(box) <= 595.28) { pageWidth = 841.89; pageHeight = 595.28; }
        else if (box.origin.x >= 0 && box.origin.y >= 0 && CGRectGetMaxX(box) <= 595.28 && CGRectGetMaxY(box) <= 841.89) { pageWidth = 595.28; pageHeight = 841.89; }
        else { pageWidth = box.size.width + 56; pageHeight = box.size.height + 56; shiftX = 28 - box.origin.x; shiftY = 28 - box.origin.y; }

        RVNGPropertyList page;
        page.insert("svg:width", pageWidth / PT, librevenge::RVNG_INCH);
        page.insert("svg:height", pageHeight / PT, librevenge::RVNG_INCH);
        painter.startDocument(RVNGPropertyList());
        painter.startPage(page);
        auto X = [&](double v) { return (v / 10 + shiftX) / PT; };
        auto Y = [&](double v) { return (pageHeight - (v / 10 + shiftY)) / PT; };
        auto point = [&](RVNGPropertyList &e, const char *kx, const char *ky, double x, double y) {
            e.insert(kx, X(x), librevenge::RVNG_INCH);
            e.insert(ky, Y(y), librevenge::RVNG_INCH);
        };
        for (const Item &item : items) {
            if (item.kind == Item::Text) {
                CGPoint at = CGPointApplyAffineTransform(CGPointMake(item.x1, item.y1 - item.ascent * 10), item.matrix);
                CGAffineTransform m = item.matrix;
                m.tx = m.ty = 0;
                painter.drawPlacedText(item.text, fontName(item.font), item.fontSize, colorOf(item.color), item.width,
                                       CGPointMake(at.x / 10 + shiftX, at.y / 10 + shiftY), m, pageHeight);
                continue;
            }
            painter.setStyle(styleOf(item, warnings));
            if (item.kind == Item::Ellipse) {
                RVNGPropertyList e;
                double rx = fabs(item.x2 - item.x1) / 2, ry = fabs(item.y2 - item.y1) / 2;
                e.insert("svg:cx", X((item.x1 + item.x2) / 2), librevenge::RVNG_INCH);
                e.insert("svg:cy", Y((item.y1 + item.y2) / 2), librevenge::RVNG_INCH);
                e.insert("svg:rx", rx / 10 / PT, librevenge::RVNG_INCH);
                e.insert("svg:ry", ry / 10 / PT, librevenge::RVNG_INCH);
                painter.drawEllipse(e);
                continue;
            }
            RVNGPropertyListVector path;
            if (item.kind == Item::Line) {
                RVNGPropertyList a, b;
                a.insert("librevenge:path-action", "M"); point(a, "svg:x", "svg:y", item.x1, item.y1);
                b.insert("librevenge:path-action", "L"); point(b, "svg:x", "svg:y", item.x2, item.y2);
                path.append(a); path.append(b);
            } else {
                size_t n = item.points.size();
                RVNGPropertyList start;
                start.insert("librevenge:path-action", "M");
                point(start, "svg:x", "svg:y", item.points[0].x, item.points[0].y);
                path.append(start);
                for (size_t i = 1; i < n + (item.closed ? 1 : 0); ++i) {
                    const Anchor &from = item.points[i - 1], &to = item.points[i % n];
                    RVNGPropertyList c;
                    c.insert("librevenge:path-action", "C");
                    point(c, "svg:x1", "svg:y1", from.outX, from.outY);
                    point(c, "svg:x2", "svg:y2", to.inX, to.inY);
                    point(c, "svg:x", "svg:y", to.x, to.y);
                    path.append(c);
                }
                if (item.closed) {
                    RVNGPropertyList z;
                    z.insert("librevenge:path-action", "Z");
                    path.append(z);
                }
            }
            RVNGPropertyList l;
            l.insert("svg:d", path);
            painter.drawPath(l);
        }
        painter.endPage();
        painter.endDocument();
        if (skipped) warnings.insert("Alcuni elementi del file non sono stati riconosciuti: il disegno può essere incompleto.");
        return true;
    }

private:
    struct Anchor { double x, y, inX, inY, outX, outY; };
    struct Item {
        enum Kind { Path, Line, Ellipse, Text } kind = Path;
        unsigned fill = 0, line = 0, font = 0, color = 0;
        bool closed = false;
        double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
        std::vector<Anchor> points;
        NSString *text = nil;
        double fontSize = 12, width = 0, ascent = 0;
        CGAffineTransform matrix = CGAffineTransformIdentity;
    };
    struct Record { size_t offset = 0; unsigned type = 0; };

    const uint8_t *d;
    size_t size;
    std::vector<Record> records;  // l'indice è il numero del record: 1 è il primo
    std::vector<Item> items;
    bool skipped = false;

    unsigned u16(size_t o) const { return o + 2 <= size ? (d[o] << 8) | d[o + 1] : 0; }
    uint32_t u32(size_t o) const { return o + 4 <= size ? ((uint32_t)u16(o) << 16) | u16(o + 2) : 0; }
    double fixed(size_t o) const { return (int32_t)u32(o) / 65536.0; }

    size_t lengthOf(unsigned type, size_t o) const {
        switch (type) {
            case 0x0005: return 12 + 2 * u16(o + 6);
            case 0x0006: return o + 6 < size ? 7 + d[o + 6] : 0;
            case 0x1389: return 34;
            case 0x138a: return 36 + 2 * u16(o + 34);
            case 0x13ed: return 48;
            case 0x13ee: return 160 + u16(o + 82);
            case 0x1452: return 20;
            case 0x1453: return 18;
            case 0x1455: return 30;
            case 0x14b5: return 16;
            case 0x14b6: return 26;
            case 0x14b7: return 20;
            case 0x14b8: return 22;
            case 0x14c9: case 0x14ca: return 12;
            case 0x14d3: return 22;
            case 0x14d4: return 30;
            case 0x14dd: return 62;
            case 0x151a: return 40;
            case 0x151c: return 32 + 16 * u16(o + 30);
            case 0x151d: return 36;
            case 0x157d: return 14 + 2 * u16(o + 12);
            default: return 0;
        }
    }

    bool walk() {
        size_t o = 0;
        while (o + 6 <= size && !(u16(o + 4) == 0x1389 && u32(o) > 0 && u32(o) < 4096)) ++o;
        if (o + 6 > size) return false;
        records.push_back(Record());
        while (o + 6 <= size) {
            uint32_t declared = u32(o);
            unsigned type = u16(o + 4);
            size_t length = (declared >= 6 && declared < (1u << 24)) ? lengthOf(type, o) : 0;
            if (length == 0 || o + length > size) {
                // Elemento sconosciuto: cerca il prossimo record riconoscibile, che riceve il numero successivo.
                size_t next = o + 1;
                while (next + 6 <= size && !(u32(next) >= 6 && u32(next) < (1u << 16) && lengthOf(u16(next + 4), next) > 0 && next + lengthOf(u16(next + 4), next) <= size)) ++next;
                if (next + 6 > size) { if (size - o > 8) skipped = true; break; }
                skipped = true;
                records.push_back({o, 0});
                o = next;
                continue;
            }
            records.push_back({o, type});
            read(type, o);
            o += length;
        }
        return !items.empty();
    }

    void read(unsigned type, size_t o) {
        if (type == 0x151c) {
            Item item;
            item.fill = u16(o + 20); item.line = u16(o + 22);
            item.closed = u16(o + 28) != 0;
            size_t p = o + 32;
            for (unsigned i = 0, n = u16(o + 30); i < n; ++i, p += 16)
                item.points.push_back({(double)u16(p + 4), (double)u16(p + 6), (double)u16(p + 8), (double)u16(p + 10), (double)u16(p + 12), (double)u16(p + 14)});
            if (!item.points.empty()) items.push_back(item);
        } else if (type == 0x151d || type == 0x151a) {
            Item item;
            item.kind = type == 0x151d ? Item::Line : Item::Ellipse;
            item.fill = u16(o + 20); item.line = u16(o + 22);
            item.x1 = u16(o + 28); item.y1 = u16(o + 30); item.x2 = u16(o + 32); item.y2 = u16(o + 34);
            items.push_back(item);
        } else if (type == 0x13ee) {
            Item item;
            item.kind = Item::Text;
            item.x1 = u16(o + 32); item.y1 = u16(o + 34); item.x2 = u16(o + 36); item.y2 = u16(o + 38);
            item.matrix = CGAffineTransformMake(fixed(o + 44), fixed(o + 48), fixed(o + 52), fixed(o + 56), fixed(o + 60), fixed(o + 64));
            item.font = u16(o + 92); item.fontSize = u16(o + 94); item.color = u16(o + 106);
            item.width = fixed(o + 144); item.ascent = fixed(o + 148);
            item.text = [[NSString alloc] initWithBytes:d + o + 160 length:u16(o + 82) encoding:NSMacOSRomanStringEncoding];
            if (item.text.length) items.push_back(item);
        }
    }

    CGRect bounds() const {
        CGRect box = CGRectNull;
        auto add = [&](double x, double y) { box = CGRectUnion(box, CGRectMake(x / 10, y / 10, 0, 0)); };
        for (const Item &item : items) {
            if (item.kind == Item::Text) {
                for (double x : {item.x1, item.x2}) for (double y : {item.y1, item.y2}) {
                    CGPoint p = CGPointApplyAffineTransform(CGPointMake(x, y), item.matrix);
                    add(p.x, p.y);
                }
            } else if (item.kind == Item::Path) {
                for (const Anchor &a : item.points) add(a.x, a.y);
            } else {
                add(item.x1, item.y1); add(item.x2, item.y2);
            }
        }
        return box;
    }

    // Colore 0 = bianco; gli altri rimandano a un record con il valore RGB a 16 bit.
    std::string colorOf(unsigned id) const {
        if (id == 0 || id >= records.size()) return "#ffffff";
        size_t o = records[id].offset;
        char hex[8];
        snprintf(hex, sizeof hex, "#%02x%02x%02x", u16(o + 8) >> 8, u16(o + 10) >> 8, u16(o + 12) >> 8);
        return hex;
    }
    std::string fontName(unsigned id) const {
        if (id == 0 || id >= records.size() || records[id].type != 0x0006) return "Helvetica";
        size_t o = records[id].offset;
        NSString *s = [[NSString alloc] initWithBytes:d + o + 7 length:d[o + 6] encoding:NSMacOSRomanStringEncoding];
        return s ? std::string(s.UTF8String) : "Helvetica";
    }
    RVNGPropertyList styleOf(const Item &item, std::set<std::string> &warnings) const {
        RVNGPropertyList s;
        s.insert("draw:fill", "none");
        s.insert("draw:stroke", "none");
        if (item.kind != Item::Line && item.fill && item.fill < records.size()) {
            const Record &r = records[item.fill];
            if (r.type != 0x14b5) warnings.insert("Alcuni riempimenti speciali del vecchio formato sono stati resi con un colore pieno.");
            s.insert("draw:fill", "solid");
            s.insert("draw:fill-color", colorOf(u16(r.offset + 12)).c_str());
        }
        if (item.line && item.line < records.size() && records[item.line].type == 0x14b6) {
            const Record &r = records[item.line];
            s.insert("draw:stroke", "solid");
            s.insert("svg:stroke-color", colorOf(u16(r.offset + 12)).c_str());
            s.insert("svg:stroke-width", u16(r.offset + 20) / 10.0 / PT, librevenge::RVNG_INCH);
            s.insert("svg:stroke-miterlimit", fixed(r.offset + 16), librevenge::RVNG_GENERIC);
        }
        return s;
    }
};

// Dà al font incorporato il nome di quello originale: i programmi che elencano i font del PDF, come
// Illustrator, possono così mostrare quale carattere manca, mentre i disegni delle lettere restano quelli
// del sostituto. Cambiando le lunghezze si aggiorna la tabella delle posizioni; se il PDF non ha la forma
// attesa, il file resta com'è (i nomi originali sono comunque nelle parole chiave del documento).
void renameEmbeddedFonts(NSString *path, const std::map<std::string, std::string> &substitutions) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || substitutions.empty()) return;
    std::string pdf((const char *)data.bytes, data.length);
    size_t startxrefAt = pdf.rfind("startxref");
    if (startxrefAt == std::string::npos) return;
    size_t xref = strtoul(pdf.c_str() + startxrefAt + 9, nullptr, 10);
    if (xref + 4 >= pdf.size() || pdf.compare(xref, 4, "xref") != 0) return;

    struct Edit { size_t at, length; std::string text; };
    std::vector<Edit> edits;
    std::set<std::string> taken;
    for (const auto &entry : substitutions) {
        if (!taken.insert(entry.second).second) continue;  // due originali sullo stesso font: un solo nome possibile
        std::string clean;
        for (char c : entry.first) if (isalnum((unsigned char)c) || c == '-' || c == '_') clean += c;
        if (clean.empty()) continue;
        for (const char *key : {"/BaseFont /", "/FontName /"}) {
            for (size_t at = pdf.find(key); at != std::string::npos; at = pdf.find(key, at + 1)) {
                size_t tag = at + strlen(key);
                if (tag + 7 + entry.second.size() >= pdf.size() || pdf[tag + 6] != '+') continue;
                size_t name = tag + 7;
                char after = pdf[name + entry.second.size()];
                bool delimiter = isspace((unsigned char)after) || after == '/' || after == '>' || after == '[' || after == '<';
                if (pdf.compare(name, entry.second.size(), entry.second) == 0 && delimiter)
                    edits.push_back({name, entry.second.size(), clean});
            }
        }
    }
    if (edits.empty()) return;
    std::sort(edits.begin(), edits.end(), [](const Edit &a, const Edit &b) { return a.at < b.at; });
    auto moved = [&](size_t offset) {
        long shift = 0;
        for (const Edit &e : edits) {
            if (e.at >= offset) break;
            shift += (long)e.text.size() - (long)e.length;
        }
        return (size_t)((long)offset + shift);
    };

    // Tabella classica: righe "xref", "0 N", poi N voci di 20 byte.
    size_t line = pdf.find('\n', xref);
    if (line == std::string::npos) return;
    unsigned first = 0, count = 0;
    if (sscanf(pdf.c_str() + line + 1, "%u %u", &first, &count) != 2) return;
    size_t entries = pdf.find('\n', line + 1);
    if (entries == std::string::npos || entries + 1 + 20 * (size_t)count > startxrefAt) return;
    entries += 1;
    std::string table;
    for (unsigned i = 0; i < count; ++i) {
        std::string row = pdf.substr(entries + 20 * i, 20);
        if (row[17] == 'n') {
            char offset[12];
            snprintf(offset, sizeof offset, "%010zu", moved(strtoul(row.c_str(), nullptr, 10)));
            row.replace(0, 10, offset);
        } else if (row[17] != 'f') {
            return;
        }
        table += row;
    }
    size_t newXref = moved(xref);
    std::string out;
    size_t from = 0;
    for (const Edit &e : edits) {
        out.append(pdf, from, e.at - from);
        out += e.text;
        from = e.at + e.length;
    }
    out.append(pdf, from, entries - from);
    out += table;
    size_t afterTable = entries + 20 * (size_t)count;
    out.append(pdf, afterTable, startxrefAt - afterTable);
    out += "startxref\n" + std::to_string(newXref) + "\n%%EOF\n";
    [[NSData dataWithBytes:out.data() length:out.size()] writeToFile:path atomically:YES];
}

NSString *fontKeywords(const PDFPainter &painter) {
    if (painter.fontNotes.empty()) return nil;
    NSMutableArray *fonts = [NSMutableArray array];
    for (const std::string &f : painter.fontNotes) [fonts addObject:@(f.c_str())];
    return [@"Font originali mancanti: " stringByAppendingString:[fonts componentsJoinedByString:@"; "]];
}

// Il primo passaggio scopre i font mancanti; il secondo li scrive nelle informazioni del documento,
// che il PDF deve conoscere fin dall'inizio.
template <typename Draw>
bool drawWithFontNames(NSString *output, Draw draw, std::set<std::string> &fontNotes, std::set<std::string> &warnings, int &hidden) {
    std::map<std::string, std::string> substitutions;
    NSString *keywords = nil;
    bool ok;
    {
        PDFPainter painter(output);
        ok = draw(painter);
        fontNotes = painter.fontNotes; warnings = painter.warnings;
        substitutions = painter.substitutions; hidden = painter.hiddenLayers;
        keywords = fontKeywords(painter);
        if (ok && !painter.drewPage) ok = false;
    }
    if (ok && keywords) {
        { PDFPainter painter(output, keywords); ok = draw(painter); }
        if (ok) renameEmbeddedFonts(output, substitutions);
    }
    return ok;
}

}  // namespace

BOOL FHIsSupported(NSString *path) {
    NSData *head = [[NSFileHandle fileHandleForReadingAtPath:path] readDataOfLength:8];
    if (head && OldFreeHand::matches(head)) return YES;
    try {
        librevenge::RVNGFileStream input(path.fileSystemRepresentation);
        return libfreehand::FreeHandDocument::isSupported(&input);
    } catch (...) {
        return NO;
    }
}

FHConversion *FHConvertToPDF(NSString *input, NSString *output, BOOL includeHiddenLayers) {
    FHConversion *result = [FHConversion new];
    result.notes = @[];
    libfreehand::includeHiddenLayers = includeHiddenLayers;
    std::set<std::string> fontNotes, warnings;
    int hidden = 0;
    NSMutableArray *notes = [NSMutableArray array];
    auto collectNotes = [&] {
        if (!fontNotes.empty()) {
            NSMutableArray *fonts = [NSMutableArray array];
            for (const std::string &f : fontNotes) [fonts addObject:@(f.c_str())];
            [notes addObject:[@"Font non installati, sostituiti: " stringByAppendingString:[fonts componentsJoinedByString:@", "]]];
        }
        for (const std::string &w : warnings) [notes addObject:@(w.c_str())];
        result.notes = notes;
    };
    NSData *whole = [NSData dataWithContentsOfFile:input];
    if (whole && OldFreeHand::matches(whole)) {
        [notes addObject:@"Formato FreeHand molto vecchio: lettura sperimentale, controlla il risultato."];
        bool ok = drawWithFontNames(output, [&](PDFPainter &painter) {
            OldFreeHand old(whole);
            return old.draw(painter, painter.warnings);
        }, fontNotes, warnings, hidden);
        collectNotes();
        if (ok) result.ok = YES;
        else result.error = @"formato FreeHand molto vecchio: questo file non si è potuto leggere.";
        return result;
    }
    try {
        {
            librevenge::RVNGFileStream stream(input.fileSystemRepresentation);
            if (!libfreehand::FreeHandDocument::isSupported(&stream)) {
                result.error = @"non sembra un file FreeHand.";
                return result;
            }
        }
        bool ok = drawWithFontNames(output, [&](PDFPainter &painter) {
            librevenge::RVNGFileStream stream(input.fileSystemRepresentation);
            return (bool)libfreehand::FreeHandDocument::parse(&stream, &painter);
        }, fontNotes, warnings, hidden);
        collectNotes();
        if (!ok) {
            result.error = @"il file è danneggiato o usa funzioni che il lettore non capisce.";
            return result;
        }
        result.ok = YES;
        result.includedHiddenLayers = includeHiddenLayers && hidden > 0;
    } catch (const std::exception &e) {
        result.error = [@"errore durante la lettura: " stringByAppendingString:@(e.what())];
    } catch (...) {
        result.error = @"errore durante la lettura del file.";
    }
    return result;
}

FHConversion *FHConvertToAI(NSString *input, NSString *output) {
    FHConversion *result = [FHConversion new];
    result.notes = @[];
    // Nel .ai i livelli nascosti restano nascosti ma presenti: si riaccendono da Illustrator.
    libfreehand::includeHiddenLayers = true;
    AIWriter writer;
    PDFPainter painter(output, nil, &writer);
    NSData *whole = [NSData dataWithContentsOfFile:input];
    bool ok = false;
    NSMutableArray *notes = [NSMutableArray array];
    try {
        if (whole && OldFreeHand::matches(whole)) {
            [notes addObject:@"Formato FreeHand molto vecchio: lettura sperimentale, controlla il risultato."];
            OldFreeHand old(whole);
            ok = old.draw(painter, painter.warnings);
        } else {
            librevenge::RVNGFileStream stream(input.fileSystemRepresentation);
            if (!libfreehand::FreeHandDocument::isSupported(&stream)) {
                result.error = @"non sembra un file FreeHand.";
                return result;
            }
            ok = libfreehand::FreeHandDocument::parse(&stream, &painter);
        }
    } catch (...) {
        ok = false;
    }
    if (!painter.fontNotes.empty()) {
        NSMutableArray *fonts = [NSMutableArray array];
        for (const std::string &f : painter.fontNotes) [fonts addObject:@(f.c_str())];
        [notes addObject:[@"Font non installati, nomi originali conservati: " stringByAppendingString:[fonts componentsJoinedByString:@", "]]];
    }
    if (painter.hiddenLayers > 0) [notes addObject:[NSString stringWithFormat:@"%d livelli nascosti in FreeHand restano nascosti: si riaccendono dal pannello Livelli.", painter.hiddenLayers]];
    for (const std::string &w : painter.warnings) {
        if (w.find("ivell") == std::string::npos) [notes addObject:@(w.c_str())];
    }
    result.notes = notes;
    if (!ok || !painter.drewPage) {
        result.error = @"il file è danneggiato o usa funzioni che il lettore non capisce.";
        return result;
    }
    std::string title = input.lastPathComponent.stringByDeletingPathExtension.UTF8String ?: "";
    if (!writer.write(output, AIWriter::quoted(@(title.c_str())))) {
        result.error = @"non sono riuscito a scrivere il file .ai.";
        return result;
    }
    result.ok = YES;
    return result;
}
