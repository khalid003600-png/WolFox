#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string>
#import <vector>
#import <algorithm>
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

// The iPhone bar under the video comes in the watch response as a list of
// buttons whose last entry is ⋯. YouTube's template shows as many as fit and
// moves the rest into ⋯, next to the ⋯ entry's own items (Save, Download,
// Report). Rewriting that list before the response is parsed puts YouTube's
// own buttons in the user's order, drops hidden ones, and lets ⋯ items take
// the free spots.

// Buttons YouTube has sent this device, so the editor only offers ones that
// exist here (Clip, Thanks and the like only show on some videos).
extern "C" void WolFoxNoteActionBarButtons(NSArray<NSString *> *names) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    NSString *const key = @"WolFox.State.ActionBarSeen";
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults objectForKey:key];
        seen = [NSMutableSet setWithArray:[stored isKindOfClass:NSArray.class] ? stored : @[]];
    });
    BOOL added = NO;
    @synchronized (seen) {
        for (NSString *name in names) {
            if (name.length != 0 && ![seen containsObject:name]) {
                [seen addObject:name];
                added = YES;
            }
        }
        if (added) [NSUserDefaults.standardUserDefaults setObject:seen.allObjects forKey:key];
    }
}

namespace {

struct PBField {
    uint64_t number;
    int type;
    uint64_t value;
    std::string bytes;
};

bool PBReadVarint(const std::string &data, size_t &index, uint64_t &out) {
    out = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (index >= data.size()) return false;
        const uint8_t byte = (uint8_t)data[index++];
        out |= (uint64_t)(byte & 0x7f) << shift;
        if (byte < 0x80) return true;
    }
    return false;
}

void PBWriteVarint(std::string &out, uint64_t value) {
    while (value >= 0x80) {
        out.push_back((char)((value & 0x7f) | 0x80));
        value >>= 7;
    }
    out.push_back((char)value);
}

bool PBParse(const std::string &data, std::vector<PBField> &fields) {
    size_t index = 0;
    while (index < data.size()) {
        uint64_t key = 0;
        if (!PBReadVarint(data, index, key)) return false;
        PBField field;
        field.number = key >> 3;
        field.type = (int)(key & 7);
        field.value = 0;
        if (field.number == 0) return false;
        switch (field.type) {
            case 0:
                if (!PBReadVarint(data, index, field.value)) return false;
                break;
            case 1:
                if (index + 8 > data.size()) return false;
                field.bytes = data.substr(index, 8);
                index += 8;
                break;
            case 5:
                if (index + 4 > data.size()) return false;
                field.bytes = data.substr(index, 4);
                index += 4;
                break;
            case 2: {
                uint64_t length = 0;
                if (!PBReadVarint(data, index, length) || length > data.size() - index) return false;
                field.bytes = data.substr(index, (size_t)length);
                index += (size_t)length;
                break;
            }
            default:
                return false;
        }
        fields.push_back(std::move(field));
    }
    return true;
}

std::string PBSerialize(const std::vector<PBField> &fields) {
    std::string out;
    for (const PBField &field : fields) {
        PBWriteVarint(out, (field.number << 3) | (uint64_t)field.type);
        if (field.type == 0) {
            PBWriteVarint(out, field.value);
        } else if (field.type == 2) {
            PBWriteVarint(out, field.bytes.size());
            out += field.bytes;
        } else {
            out += field.bytes;
        }
    }
    return out;
}

PBField PBMessage(uint64_t number, const std::string &bytes) {
    PBField field;
    field.number = number;
    field.type = 2;
    field.value = 0;
    field.bytes = bytes;
    return field;
}

bool PBContains(const std::string &data, const char *needle) {
    return data.find(needle) != std::string::npos;
}

// Field numbers in the bar model.
const uint64_t WolFoxBarModelField = 2185;      // the bar
const uint64_t WolFoxBarEntryField = 1;         // one button, repeated
const uint64_t WolFoxEntryRendererField = 10;   // the button's renderer
const uint64_t WolFoxOverflowField = 37098;     // ⋯, inside its renderer
const uint64_t WolFoxOverflowItemField = 2;     // ⋯'s own items
const uint64_t WolFoxOverflowCopyField = 3;     // menu versions of the bar buttons

// The renderer kinds whose field number says what they are.
const uint64_t WolFoxLikeRenderer = 484585818;
const uint64_t WolFoxDislikeRenderer = 484590786;
const uint64_t WolFoxSaveRenderer = 484598023;
const uint64_t WolFoxDownloadRenderer = 33561776;
const uint64_t WolFoxButtonRenderer = 461054335;
const uint64_t WolFoxAskRenderer = 489973921;

// The setting name ("Like", "Save", ...) of a renderer, or nil.
NSString *WolFoxRendererName(const std::string &renderer) {
    std::vector<PBField> fields;
    if (!PBParse(renderer, fields) || fields.empty()) return nil;
    const uint64_t kind = fields.front().number;
    if (kind == WolFoxLikeRenderer) return @"Like";
    if (kind == WolFoxDislikeRenderer) return @"Dislike";
    if (kind == WolFoxSaveRenderer) return @"Save";
    if (kind == WolFoxDownloadRenderer) return @"Download";
    if (kind == WolFoxOverflowField) return @"Overflow";
    if (kind == WolFoxAskRenderer) return @"Ask";
    if (kind != WolFoxButtonRenderer) return nil;
    if (PBContains(renderer, "/share_24pt") || PBContains(renderer, "id.video.share.button")) return @"Share";
    if (PBContains(renderer, "/spark_24pt") || PBContains(renderer, "you-chat-entrypoint")) return @"Ask";
    if (PBContains(renderer, "/flag_24pt")) return @"Report";
    if (PBContains(renderer, "/scissors")) return @"Clip";
    if (PBContains(renderer, "/remix")) return @"Remix";
    if (PBContains(renderer, "/money_heart") || PBContains(renderer, "/thanks")) return @"Thanks";
    if (PBContains(renderer, "/hype")) return @"Hype";
    if (PBContains(renderer, "/bookmark")) return @"Save";
    if (PBContains(renderer, "/download")) return @"Download";
    return nil;
}

// The renderer inside a bar entry.
bool WolFoxEntryRenderer(const std::string &entry, std::string &renderer) {
    std::vector<PBField> fields;
    if (!PBParse(entry, fields)) return false;
    for (const PBField &field : fields) {
        if (field.number == WolFoxEntryRendererField && field.type == 2) {
            renderer = field.bytes;
            return true;
        }
    }
    return false;
}

// A ⋯ item drawn in the bar (Report) gets the bar's icon-button look; the
// menu's style shows as a grey pill there.
std::string WolFoxBarVersion(const std::string &renderer) {
    std::vector<PBField> fields, button;
    if (!PBParse(renderer, fields) || fields.size() != 1 || fields.front().number != WolFoxButtonRenderer ||
        !PBParse(fields.front().bytes, button)) {
        return renderer;
    }
    // Ask and ⋯ are bare icons: style 3, kind 4, field 40 set.
    bool hasFlag = false;
    for (PBField &field : button) {
        if (field.number == 11 && field.type == 0) field.value = 3;
        if (field.number == 13 && field.type == 0) field.value = 4;
        if (field.number == 40 && field.type == 0) { field.value = 1; hasFlag = true; }
    }
    // No title: even hidden it takes room and pushes the icon left.
    button.erase(std::remove_if(button.begin(), button.end(), [](const PBField &field) {
        return field.number == 3 && field.type == 2;
    }), button.end());
    if (!hasFlag) {
        PBField flag;
        flag.number = 40;
        flag.type = 0;
        flag.value = 1;
        button.push_back(flag);
    }
    return PBSerialize({PBMessage(WolFoxButtonRenderer, PBSerialize(button))});
}

struct WolFoxBarItem {
    NSString *name;
    std::string barRenderer;
    std::string menuRenderer;
    NSUInteger position;
};

bool WolFoxRewriteBar(std::string &bar, NSArray<NSString *> *order, NSSet<NSString *> *hidden) {
    std::vector<PBField> fields;
    if (!PBParse(bar, fields)) return false;

    // The bar's buttons and the ⋯ entry.
    std::vector<WolFoxBarItem> items;
    NSInteger overflowIndex = -1;
    size_t firstEntry = SIZE_MAX;
    std::vector<PBField> overflowEntry, overflowRenderer, overflow;
    for (size_t index = 0; index < fields.size(); index++) {
        const PBField &field = fields[index];
        if (field.number != WolFoxBarEntryField || field.type != 2) continue;
        firstEntry = MIN(firstEntry, index);
        std::string renderer;
        if (!WolFoxEntryRenderer(field.bytes, renderer)) return false;
        NSString *name = WolFoxRendererName(renderer);
        if ([name isEqualToString:@"Overflow"]) {
            if (overflowIndex >= 0 || !PBParse(field.bytes, overflowEntry) || !PBParse(renderer, overflowRenderer)) {
                return false;
            }
            for (const PBField &inner : overflowRenderer) {
                if (inner.number == WolFoxOverflowField && inner.type == 2 && !PBParse(inner.bytes, overflow)) return false;
            }
            overflowIndex = (NSInteger)index;
            continue;
        }
        items.push_back({name, renderer, renderer, items.size()});
    }
    if (overflowIndex < 0 || overflow.empty()) return false;

    // Menu versions of the bar's buttons, and ⋯'s own items.
    std::vector<PBField> menuKept;
    for (const PBField &part : overflow) {
        if (part.type != 2) continue;
        NSString *name = WolFoxRendererName(part.bytes);
        if (part.number == WolFoxOverflowCopyField) {
            for (WolFoxBarItem &item : items) {
                if (name != nil && [item.name isEqualToString:name]) item.menuRenderer = part.bytes;
            }
        } else if (part.number == WolFoxOverflowItemField) {
            if (name != nil && ![name isEqualToString:@"Overflow"]) {
                items.push_back({name, WolFoxBarVersion(part.bytes), part.bytes, items.size()});
            } else {
                menuKept.push_back(part);
            }
        }
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:@"Overflow"];
    for (const WolFoxBarItem &item : items) {
        if (item.name != nil) [names addObject:item.name];
    }
    WolFoxNoteActionBarButtons(names);
    WolFoxDebugLog(@"actionbar", @"model bar=%@", [names componentsJoinedByString:@","]);
    if (order.count == 0 && hidden.count == 0) return false;

    // Hidden ones go; the rest follow the saved order, then YouTube's.
    std::vector<WolFoxBarItem> shown;
    for (const WolFoxBarItem &item : items) {
        if (item.name != nil && [hidden containsObject:item.name]) continue;
        shown.push_back(item);
    }
    std::stable_sort(shown.begin(), shown.end(), [order](const WolFoxBarItem &left, const WolFoxBarItem &right) {
        NSUInteger leftRank = left.name != nil ? [order indexOfObject:left.name] : NSNotFound;
        NSUInteger rightRank = right.name != nil ? [order indexOfObject:right.name] : NSNotFound;
        if (leftRank == NSNotFound) leftRank = order.count + left.position;
        if (rightRank == NSNotFound) rightRank = order.count + right.position;
        return leftRank < rightRank;
    });

    NSMutableArray<NSString *> *shownNames = [NSMutableArray array];
    for (const WolFoxBarItem &item : shown) [shownNames addObject:item.name ?: @"?"];
    WolFoxDebugLog(@"actionbar", @"model rewritten=%@,Overflow", [shownNames componentsJoinedByString:@","]);

    // ⋯ keeps its button and unknown items; its copies match the new bar.
    std::vector<PBField> newOverflow;
    bool copiesWritten = false;
    for (const PBField &part : overflow) {
        if (part.number == WolFoxOverflowItemField && part.type == 2) continue;
        if (part.number == WolFoxOverflowCopyField && part.type == 2) {
            if (!copiesWritten) {
                for (const PBField &kept : menuKept) newOverflow.push_back(kept);
                for (const WolFoxBarItem &item : shown) newOverflow.push_back(PBMessage(WolFoxOverflowCopyField, item.menuRenderer));
                copiesWritten = true;
            }
            continue;
        }
        newOverflow.push_back(part);
        // ⋯'s own items went right after its button.
        if (part.number == 1 && !copiesWritten) {
            for (const PBField &kept : menuKept) newOverflow.push_back(kept);
            for (const WolFoxBarItem &item : shown) newOverflow.push_back(PBMessage(WolFoxOverflowCopyField, item.menuRenderer));
            copiesWritten = true;
        }
    }
    if (!copiesWritten) {
        for (const PBField &kept : menuKept) newOverflow.push_back(kept);
        for (const WolFoxBarItem &item : shown) newOverflow.push_back(PBMessage(WolFoxOverflowCopyField, item.menuRenderer));
    }
    for (PBField &inner : overflowRenderer) {
        if (inner.number == WolFoxOverflowField) inner.bytes = PBSerialize(newOverflow);
    }
    for (PBField &part : overflowEntry) {
        if (part.number == WolFoxEntryRendererField) part.bytes = PBSerialize(overflowRenderer);
    }

    std::vector<PBField> rebuilt;
    for (size_t index = 0; index < fields.size(); index++) {
        if (index == firstEntry) {
            for (const WolFoxBarItem &item : shown) {
                rebuilt.push_back(PBMessage(WolFoxBarEntryField,
                                            PBSerialize({PBMessage(WolFoxEntryRendererField, item.barRenderer)})));
            }
            rebuilt.push_back(PBMessage(WolFoxBarEntryField, PBSerialize(overflowEntry)));
        }
        if (fields[index].number == WolFoxBarEntryField && fields[index].type == 2) continue;
        rebuilt.push_back(fields[index]);
    }
    bar = PBSerialize(rebuilt);
    return true;
}

// The chip bar (iPad, and iPhones that get the iPad layout): field 17 of
// its model is a flat list of {renderer} entries, the like/dislike pill one
// entry, and no ⋯. Reordering here instead of moving cells keeps the order
// when the row is too narrow and scrolls.
const uint64_t WolFoxChipBarModelField = 389155117;
const uint64_t WolFoxChipBarListField = 17;
const uint64_t WolFoxPillRenderer = 484586709;

bool WolFoxRewriteChipBar(std::string &model, NSArray<NSString *> *order, NSSet<NSString *> *hidden) {
    std::vector<PBField> fields;
    if (!PBParse(model, fields)) return false;
    bool changed = false;
    for (PBField &field : fields) {
        if (field.number != WolFoxChipBarListField || field.type != 2) continue;
        std::vector<PBField> list;
        if (!PBParse(field.bytes, list)) return false;
        std::vector<WolFoxBarItem> items;
        std::vector<PBField> others;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        size_t first = SIZE_MAX;
        for (size_t index = 0; index < list.size(); index++) {
            const PBField &entry = list[index];
            if (entry.number != 1 || entry.type != 2) continue;
            first = MIN(first, index);
            std::vector<PBField> parts;
            NSString *name = nil;
            bool pill = false;
            if (PBParse(entry.bytes, parts) && !parts.empty() && parts.front().type == 2) {
                std::vector<PBField> renderer;
                pill = PBParse(parts.front().bytes, renderer) && !renderer.empty() &&
                    renderer.front().number == WolFoxPillRenderer;
                name = pill ? @"Like" : WolFoxRendererName(parts.front().bytes);
            }
            if (name != nil) [names addObject:name];
            if (pill) [names addObject:@"Dislike"];
            // The pill goes only when both halves are hidden; one half is
            // collapsed in the layout hooks.
            const bool gone = name != nil && [hidden containsObject:name] &&
                (!pill || [hidden containsObject:@"Dislike"]);
            if (!gone) items.push_back({name, entry.bytes, entry.bytes, items.size()});
        }
        WolFoxNoteActionBarButtons(names);
        if (first == SIZE_MAX || (order.count == 0 && hidden.count == 0)) continue;
        std::stable_sort(items.begin(), items.end(), [order](const WolFoxBarItem &left, const WolFoxBarItem &right) {
            NSUInteger leftRank = left.name != nil ? [order indexOfObject:left.name] : NSNotFound;
            NSUInteger rightRank = right.name != nil ? [order indexOfObject:right.name] : NSNotFound;
            if (leftRank == NSNotFound) leftRank = order.count + left.position;
            if (rightRank == NSNotFound) rightRank = order.count + right.position;
            return leftRank < rightRank;
        });
        std::vector<PBField> rebuilt;
        for (size_t index = 0; index < list.size(); index++) {
            if (index == first) {
                for (const WolFoxBarItem &item : items) rebuilt.push_back(PBMessage(1, item.barRenderer));
            }
            if (list[index].number == 1 && list[index].type == 2) continue;
            rebuilt.push_back(list[index]);
        }
        field.bytes = PBSerialize(rebuilt);
        changed = true;
    }
    if (changed) model = PBSerialize(fields);
    return changed;
}

// Walks down the messages that hold the like button until a bar model.
bool WolFoxRewriteMessage(std::string &message, int depth, NSArray *order, NSSet *hidden) {
    if (depth > 40) return false;
    std::vector<PBField> fields;
    if (!PBParse(message, fields)) return false;
    bool changed = false;
    for (PBField &field : fields) {
        if (field.type != 2 || !PBContains(field.bytes, "id.video.like.button")) continue;
        if (field.number == WolFoxBarModelField) {
            std::string bar = field.bytes;
            if (WolFoxRewriteBar(bar, order, hidden)) {
                field.bytes = bar;
                changed = true;
            }
        } else if (field.number == WolFoxChipBarModelField) {
            std::string bar = field.bytes;
            if (WolFoxRewriteChipBar(bar, order, hidden)) {
                field.bytes = bar;
                changed = true;
            }
        } else if (WolFoxRewriteMessage(field.bytes, depth + 1, order, hidden)) {
            changed = true;
        }
    }
    if (changed) message = PBSerialize(fields);
    return changed;
}

NSArray<NSString *> *WolFoxBarNames(void) {
    return @[@"Like", @"Dislike", @"Share", @"Ask", @"Save", @"Download", @"Clip",
             @"Remix", @"Thanks", @"Hype", @"Report"];
}

// Extras YouTube attaches to a video in lists (search, Home, suggestions):
// - products: a row under the title with a bag icon, "1 product · Earns
//   commission", in the lockup's list of metadata rows, and the product card;
// - AI summaries: the "Summary" box under the video.
// The product card and the summary both come next to the video (field 18) in
// field 33. Field 34 only comes with them and leaves an empty expand arrow.
const uint64_t WolFoxLockupVideoField = 18;
const uint64_t WolFoxLockupAttachmentField = 33;
const uint64_t WolFoxLockupAttachmentTokenField = 34;
const uint64_t WolFoxMetadataRowsField = 514549827;
const uint64_t WolFoxMetadataRowField = 1;

const char *const WolFoxProductMarkers[] = {
    "gstatic.com/shopping", "answer/6342839", "/bag_24pt",
};
// The summary's help link and feedback tag.
const char *const WolFoxSummaryMarkers[] = {
    "answer/14089423", "PAfeedback_genai",
};

struct WolFoxLockupStrip {
    bool products;
    bool summaries;
};

bool WolFoxHasAny(const std::string &data, const char *const *markers, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (PBContains(data, markers[i])) return true;
    }
    return false;
}

bool WolFoxHasProductMarker(const std::string &data) {
    return WolFoxHasAny(data, WolFoxProductMarkers,
                        sizeof(WolFoxProductMarkers) / sizeof(*WolFoxProductMarkers));
}

bool WolFoxHasSummaryMarker(const std::string &data) {
    return WolFoxHasAny(data, WolFoxSummaryMarkers,
                        sizeof(WolFoxSummaryMarkers) / sizeof(*WolFoxSummaryMarkers));
}

bool WolFoxHasStripMarker(const std::string &data, const WolFoxLockupStrip &strip) {
    return (strip.products && WolFoxHasProductMarker(data)) ||
        (strip.summaries && WolFoxHasSummaryMarker(data));
}

// Drops the bag-icon row, and the empty row YouTube puts before it as a gap.
int WolFoxStripProductRows(std::string &rows) {
    std::vector<PBField> fields;
    if (!PBParse(rows, fields)) return 0;
    int removed = 0;
    std::vector<PBField> kept;
    kept.reserve(fields.size());
    for (PBField &field : fields) {
        if (field.number == WolFoxMetadataRowField && field.type == 2 &&
            PBContains(field.bytes, "/bag_24pt")) {
            if (!kept.empty() && kept.back().number == WolFoxMetadataRowField &&
                kept.back().type == 2 && kept.back().bytes.empty()) {
                kept.pop_back();
            }
            removed++;
            continue;
        }
        kept.push_back(std::move(field));
    }
    if (removed != 0) rows = PBSerialize(kept);
    return removed;
}

int WolFoxStripLockups(std::string &message, int depth, const WolFoxLockupStrip &strip) {
    if (depth > 40) return 0;
    std::vector<PBField> fields;
    if (!PBParse(message, fields)) return 0;
    bool lockup = false;
    bool attachment = false;
    for (const PBField &field : fields) {
        if (field.type != 2) continue;
        if (field.number == WolFoxLockupVideoField) lockup = true;
        if (field.number == WolFoxLockupAttachmentField && WolFoxHasStripMarker(field.bytes, strip)) {
            attachment = true;
        }
    }
    attachment = attachment && lockup;
    int removed = 0;
    std::vector<PBField> kept;
    kept.reserve(fields.size());
    for (PBField &field : fields) {
        if (attachment && (field.number == WolFoxLockupAttachmentField ||
                           field.number == WolFoxLockupAttachmentTokenField)) {
            if (field.number == WolFoxLockupAttachmentField) removed++;
            continue;
        }
        if (field.type == 2 && WolFoxHasStripMarker(field.bytes, strip)) {
            if (field.number == WolFoxMetadataRowsField) {
                if (strip.products) removed += WolFoxStripProductRows(field.bytes);
            } else {
                removed += WolFoxStripLockups(field.bytes, depth + 1, strip);
            }
        }
        kept.push_back(std::move(field));
    }
    if (removed != 0) message = PBSerialize(kept);
    return removed;
}

}  // namespace

static bool WolFoxDataHasAny(NSData *data, const char *const *markers, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (memmem(data.bytes, data.length, markers[i], strlen(markers[i])) != NULL) return true;
    }
    return false;
}

static NSData *WolFoxWithoutProducts(NSData *data, NSString *source) {
    if (data.length == 0) return data;
    WolFoxLockupStrip strip;
    strip.products = WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxDataHasAny(data, WolFoxProductMarkers,
                         sizeof(WolFoxProductMarkers) / sizeof(*WolFoxProductMarkers));
    strip.summaries = WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.AISummariesHidden") &&
        WolFoxDataHasAny(data, WolFoxSummaryMarkers,
                         sizeof(WolFoxSummaryMarkers) / sizeof(*WolFoxSummaryMarkers));
    if (!strip.products && !strip.summaries) return data;
    std::string message((const char *)data.bytes, data.length);
    int removed = WolFoxStripLockups(message, 0, strip);
    WolFoxDebugLog(@"products", @"%@ removed %d items (products=%d summaries=%d)",
                   source, removed, strip.products, strip.summaries);
    if (removed == 0) return data;
    return [NSData dataWithBytes:message.data() length:message.size()];
}

static NSData *WolFoxRewrittenResponse(NSData *data) {
    static const char marker[] = "id.video.like.button";
    if (data.length == 0 || !WolFoxFeatureEnabled(@"YTKACE.Preference.Enabled")) return data;
    data = WolFoxWithoutProducts(data, @"watch");
    NSArray *order = WolFoxPreferenceObject(@"YTKACE.Preference.ActionBar.Order");
    if (![order isKindOfClass:NSArray.class]) order = @[];
    NSMutableSet *hidden = [NSMutableSet set];
    for (NSString *name in WolFoxBarNames()) {
        if (WolFoxFeatureEnabled([NSString stringWithFormat:@"YTKACE.Preference.ActionBar.%@Hidden", name])) {
            [hidden addObject:name];
        }
    }
    // With nothing moved or hidden this only notes which buttons exist.
    if (memmem(data.bytes, data.length, marker, sizeof(marker) - 1) == NULL) return data;
    std::string message((const char *)data.bytes, data.length);
    if (!WolFoxRewriteMessage(message, 0, order, hidden)) return data;
    return [NSData dataWithBytes:message.data() length:message.size()];
}

static IMP OriginalGetWatchInit;
static IMP OriginalGetWatchMerge;
static IMP OriginalWatchNextInit;
static IMP OriginalSearchInit;
static IMP OriginalBrowseInit;

static id WolFoxGetWatchInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    return ((id (*)(id, SEL, id, id, NSError **))OriginalGetWatchInit)(
        receiver, selector, WolFoxRewrittenResponse(data), registry, error);
}

static void WolFoxGetWatchMerge(id receiver, SEL selector, NSData *data, id registry) {
    ((void (*)(id, SEL, id, id))OriginalGetWatchMerge)(receiver, selector, WolFoxRewrittenResponse(data), registry);
}

static id WolFoxWatchNextInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    return ((id (*)(id, SEL, id, id, NSError **))OriginalWatchNextInit)(
        receiver, selector, WolFoxRewrittenResponse(data), registry, error);
}

static id WolFoxSearchInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Enabled")) data = WolFoxWithoutProducts(data, @"search");
    return ((id (*)(id, SEL, id, id, NSError **))OriginalSearchInit)(receiver, selector, data, registry, error);
}

static id WolFoxBrowseInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Enabled")) data = WolFoxWithoutProducts(data, @"browse");
    return ((id (*)(id, SEL, id, id, NSError **))OriginalBrowseInit)(receiver, selector, data, registry, error);
}

__attribute__((constructor)) static void WolFoxInstallActionBarModelHooks(void) {
    WolFoxInstallInstanceHook(@"YTISearchResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)WolFoxSearchInit, &OriginalSearchInit);
    WolFoxInstallInstanceHook(@"YTIBrowseResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)WolFoxBrowseInit, &OriginalBrowseInit);
    WolFoxInstallInstanceHook(@"YTIGetWatchResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)WolFoxGetWatchInit, &OriginalGetWatchInit);
    WolFoxInstallInstanceHook(@"YTIGetWatchResponse", @"mergeFromData:extensionRegistry:",
                              (IMP)WolFoxGetWatchMerge, &OriginalGetWatchMerge);
    WolFoxInstallInstanceHook(@"YTIWatchNextResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)WolFoxWatchNextInit, &OriginalWatchNextInit);
}
