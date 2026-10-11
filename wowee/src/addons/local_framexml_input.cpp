#include "ui/local_game_menu_lua.hpp"
#include "addons/local_framexml.hpp"
#include "addons/lua_engine.hpp"
#include "game/local_realm.hpp"
#include "game/local_services.hpp"
#include "core/logger.hpp"
#include <vector>
#ifdef WOWEE_SWITCH
#include "platform/switch/switch_pad_buttons.h"
#endif
#include "ui/keybinding_manager.hpp"
#include "ui/framexml_pad_navigation.hpp"
#include "ui/framexml_takeover.hpp"
#include <imgui.h>
#include <cmath>
#include <algorithm>
#include <limits>
#include <utility>
extern "C" {
#include <lua.h>
}
#ifdef WOWEE_SWITCH
#include "platform/switch/input_switch.hpp"
#endif
namespace wowee::addons {
namespace {
/// Cursor ownership comes from its payload, not its artwork: a macro or a
/// spell with a missing icon still needs cancellation and a destination slot.
bool carrying(LuaEngine* engine) {
    auto* L=engine?engine->getState():nullptr;
    if(!L)return false;
    const int stack=lua_gettop(L);
    lua_getglobal(L,"GetCursorInfo");
    const bool held=lua_isfunction(L,-1) && lua_pcall(L,0,1,0)==0 && !lua_isnil(L,-1);
    lua_settop(L,stack);
    return held;
}
/// ...and whether that something is an item out of a bag or off the paperdoll,
/// which is the only kind that is destroyed rather than merely dropped.
bool carryingBagItem() { uint8_t bag=0,slot=0; return ui::frameXmlCursorWireSlot(bag,slot); }
bool shown(ui::WidgetTree& tree, const ui::Widget* w) {
    return ui::padWidgetShown(tree,w);
}
const ui::Widget* panel(ui::WidgetTree& tree) {
    const ui::Widget* result=nullptr;
    for(auto name:ui::kPadPanels) {
        auto* w=tree.findByName(std::string(name));if(!w || !w->visible || !shown(tree,w))continue;
        if(!result || w->effStrata>result->effStrata ||
            (w->effStrata==result->effStrata &&
             (w->effLevel>result->effLevel ||
              (w->effLevel==result->effLevel && w->creationOrder>result->creationOrder))))result=w;
    }
    return result;
}
/// The original interface's world map, when it is the panel on top.
///
/// By the same ordering the rest of this file uses - strata, then level, then
/// creation order - so a bag opened over the map is on top of it and gets the
/// pad back, exactly as it would over any other panel.
const ui::Widget* worldMapPanel(ui::WidgetTree& tree) {
    const auto* top=panel(tree);
    return top && top->name=="WorldMapFrame" ? top : nullptr;
}
/// Draw the pad's focus outline on a control, on the button's own rect.
void drawPadFocus(const ui::Widget& w,ui::WidgetTree& tree,float uiScale,float displayHeight) {
    // Micro buttons have a tall transparent upper area excluded by FrameXML's
    // HitRectInsets. The pad must outline the same area the mouse can click.
    const float es = w.effScale;
    const float l = std::clamp(w.hitInsetLeft * es, 0.f, w.rectW * .49f);
    const float rInset = std::clamp(w.hitInsetRight * es, 0.f, w.rectW * .49f);
    const float t = std::clamp(w.hitInsetTop * es, 0.f, w.rectH * .9f);
    const float b = std::clamp(w.hitInsetBottom * es, 0.f, w.rectH * .49f);
    float left=w.left+l,bottom=w.bottom+b,width=w.rectW-l-rInset,height=w.rectH-t-b;
    // HitRectInsets describe the clickable area, which still includes blank
    // pixels above the micro icon. Outline its actual normal artwork instead
    // of adding another fixed race/resolution-dependent inset.
    for(auto id:w.children) {
        const auto* art=tree.get(id);
        if(!art || art->buttonArt!=ui::ButtonArt::Normal || !art->textureContent.valid || art->texCoordRotated)continue;
        float x0,x1,y0,y1;const auto& ink=art->textureContent;
        if(!ui::contentAxis(art->texCoord[0],art->texCoord[1],ink.left,ink.right,x0,x1) ||
           !ui::contentAxis(art->texCoord[2],art->texCoord[3],ink.top,ink.bottom,y0,y1))continue;
        const float right=std::min(left+width,art->left+x1*art->rectW);
        const float top=std::min(bottom+height,art->bottom+(1-y0)*art->rectH);
        left=std::max(left,art->left+x0*art->rectW);
        bottom=std::max(bottom,art->bottom+(1-y1)*art->rectH);
        width=std::max(0.f,right-left);height=std::max(0.f,top-bottom);
        break;
    }
    const auto r=padFocusRect(left,bottom,width,height,uiScale,displayHeight);
    ImGui::GetForegroundDrawList()->AddRect(ImVec2(r.x0,r.y0),ImVec2(r.x1,r.y1),
        IM_COL32(255,215,100,255),2,0,kPadFocusThickness);
}
}
void LocalFrameXml::publishPadCursor() {
#ifdef WOWEE_SWITCH
    if (platform::switchport::consolePortActive()) {
        ui::frameXmlClearPadCursorAnchor();
        return;
    }
#endif
    if(!engine_){ui::frameXmlClearPadCursorAnchor();return;}
    auto& tree=engine_->widgets();
    // The bar lane wins where both have a selection: it is the explicit one -
    // chosen with a shoulder press and kept across frames - while the panel
    // lane's focus is whatever the D-pad last landed on.
    const ui::Widget* w=tree.get(padFocus_.widget);
    if(!w || !w->visible)w=tree.get(focus_);
    if(!w || !w->visible){ui::frameXmlClearPadCursorAnchor();return;}
    const float scale=tree.uiScale();
    ui::frameXmlSetPadCursorAnchor((w->left+w->rectW*.5f)*scale,
        ImGui::GetIO().DisplaySize.y-(w->bottom+w->rectH*.5f)*scale);
}
bool LocalFrameXml::activatePadControl(uint32_t id) {
    if(!panelTreeLive())return false;
    auto& tree=engine_->widgets();const auto* w=tree.get(id);
    if(!ui::padControlPoint(tree,w,ImGui::GetIO().DisplaySize.x/tree.uiScale(),
        ImGui::GetIO().DisplaySize.y/tree.uiScale()))return false;
    if(w->name.starts_with("BankFrameItem") || w->name.starts_with("ContainerFrame")) {
        if(engine_->executeString("__WoWPSBankPadHandled = WoWPS_LocalBankActivate and WoWPS_LocalBankActivate('"+w->name+"') or false")) {
            auto* L=engine_->getState();lua_getglobal(L,"__WoWPSBankPadHandled");bool handled=lua_toboolean(L,-1)!=0;lua_pop(L,1);if(handled)return true;
        }
        w=tree.get(id);if(!w)return true;
    }
    // Square buys through retail's confirmation handler, and sells the chosen
    // bag stack while a merchant is open. Other panels retain mouse semantics.
    if(w->name.starts_with("MerchantItem") || w->name.starts_with("ContainerFrame")) {
        const std::string name=w->name;
        if(engine_->executeString("__WoWPSMerchantPadHandled = WoWPS_LocalMerchantActivate and WoWPS_LocalMerchantActivate('"+name+"') or false")) {
            auto* L=engine_->getState();lua_getglobal(L,"__WoWPSMerchantPadHandled");
            const bool handled=lua_toboolean(L,-1)!=0;lua_pop(L,1);
            if(handled)return true;
        }
        // A callback can rebuild the widget tree. Reacquire before geometry.
        w=tree.get(id);if(!w || !w->visible || !w->enabled)return true;
    }
    const float screenH=ImGui::GetIO().DisplaySize.y;
    const auto point=ui::padControlPoint(tree,w,ImGui::GetIO().DisplaySize.x/tree.uiScale(),screenH/tree.uiScale());
    if(!point)return true;
    const float x=point->x*tree.uiScale(),y=screenH-point->y*tree.uiScale();
    // CharacterMicroButton toggles on OnMouseUp, not OnClick. Use the same
    // complete press/release path as a mouse so IsMouseOver, checked state,
    // PreClick/PostClick and mouse-only handlers agree for every control.
    engine_->dispatchMouse(x,y,screenH,{false,false,false});
    if(!panelTreeLive())return true;
    engine_->dispatchMouse(x,y,screenH,{true,false,false});
    if(panelTreeLive())engine_->dispatchMouse(x,y,screenH,{false,false,false});
    return true;
}
bool LocalFrameXml::padPickup(const std::string& name) {
    if(!engine_)return false;
    const auto target=padPickupTargetForName(name);
    if(target.kind==PadPickupTarget::Kind::None)return false;
    // The slot numbers come from the widget, never from its name: a
    // ContainerFrame is bound to whichever bag it was opened for and an action
    // button to whichever page the bar is showing, and both change under a name
    // that does not. The name only says which of the three calls owns the press.
    const std::string lookup="local b=_G['"+name+"']; if not b then return end ";
    switch(target.kind){
    case PadPickupTarget::Kind::Container:
        return engine_->executeString(lookup+
            "local parent=b.GetParent and b:GetParent(); "
            "local bag=b.bag or (parent and parent.GetID and parent:GetID()); "
            "local slot=b.slot or (b.GetID and b:GetID()); "
            "if bag and slot and PickupContainerItem then PickupContainerItem(bag,slot) end");
    case PadPickupTarget::Kind::Spellbook:
        // The book slot is not the button number: the frame pages, and
        // SpellBook_GetSpellID is the interface's own translation of the two.
        return engine_->executeString(lookup+
            "local id=(SpellBook_GetSpellID and SpellBook_GetSpellID(b:GetID())) or b:GetID(); "
            "local book=(SpellBookFrame and SpellBookFrame.bookType) or BOOKTYPE_SPELL or 'spell'; "
            "if PickupSpellBookItem then PickupSpellBookItem(id,book) end");
    case PadPickupTarget::Kind::Action:
        return engine_->executeString(lookup+
            "local slot=b.action or (b.GetAttribute and b:GetAttribute('action')) or b:GetID(); "
            "if type(slot)=='number' then if GetCursorInfo and GetCursorInfo() then if PlaceAction then PlaceAction(slot) end elseif PickupAction then PickupAction(slot) end end");
    case PadPickupTarget::Kind::None:break;
    }
    return false;
}
/// Cross with something on the cursor and nowhere here to put it.
///
/// Out of the window that owns it is how a carried thing is let go of, and what
/// that means depends on what is being carried. A bag item is destroyed, so the
/// interface's own confirmation is raised first and the cursor keeps the item
/// until the answer comes back - the popup's Accept is what deletes it. Anything
/// else came off a bar or out of the spellbook, where the slot held a reference
/// rather than the thing itself, so letting go is all there is to do and the
/// real client asks nothing.
bool LocalFrameXml::padDropCarried() {
    if(!engine_ || !carrying(engine_))return false;
    if(engine_->executeString("__WoWPSLocalDrop = WoWPS_LocalSocialDrop and WoWPS_LocalSocialDrop() or false")){
        auto* L=engine_->getState();lua_getglobal(L,"__WoWPSLocalDrop");const bool handled=lua_toboolean(L,-1)!=0;lua_pop(L,1);if(handled)return true;
    }
    if(carryingBagItem()){
        LOG_INFO("[PAD_UI] Cross released a bag item outside a slot; asking before destroying it");
        engine_->fireEvent("WOWEE_DELETE_ITEM_CONFIRM");
    }else{
        LOG_INFO("[PAD_UI] Cross dropped the carried action outside a slot");
        ui::frameXmlPutCursorDown();
    }
    return true;
}
bool LocalFrameXml::worldMapOwnsPad() const {
    return panelTreeLive() && worldMapPanel(engine_->widgets())!=nullptr;
}

/// The map's own button.
///
/// Read from the raw pad rather than bound to a scancode in kBindings, for the
/// half that matters: while a menu owns the pad the binding table is skipped
/// entirely, so a table row could open the map and could never close it again.
/// The table still carries the button, as the one place the mapping is written
/// down - Action::WorldMap, doing nothing on its own and saying who does.
bool LocalFrameXml::padWorldMapToggle() {
#ifdef WOWEE_SWITCH
    if(!panelTreeLive() || platform::switchport::keyboardCapturesInput() || platform::switchport::inputTextFocus())return false;
    const auto& pad=platform::switchport::padSnapshot();
    if(!pad.connected || ImGui::GetIO().WantTextInput)return false;
    if(!(pad.pressed&kPadWorldMapButton))return false;
    auto& tree=engine_->widgets();
    const auto* top=panel(tree);
    // A dialog waiting for an answer keeps the pad: raising the map over a
    // delete confirmation would leave the question underneath it with the Yes
    // no longer reachable.
    if(top && (ui::padModalPanel(top->name)))return false;
    const auto* map=tree.findByName("WorldMapFrame");
    const bool open=map && map->visible;
    LOG_INFO("[PAD_UI] World map ",open?"closed":"opened"," from the pad");
    engine_->executeString(open
        ? "if WorldMapFrame then if HideUIPanel then HideUIPanel(WorldMapFrame) "
          "else WorldMapFrame:Hide() end end"
        // Where the player is, and then the map. The map remembers whatever
        // zone it was last left on, so without this it opens on somewhere
        // else's coastline - which is not an answer to "where am I". The
        // interface's own minimap button does exactly this pair.
        : "if SetMapToCurrentZone then SetMapToCurrentZone() end "
          "if ToggleWorldMap then ToggleWorldMap() elseif WorldMapFrame then "
          "if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end end");
    return true;
#else
    return false;
#endif
}

/// One frame of the map, while it is the panel on top.
///
/// The map is read with a pointer, not with a focus ring: what a press means
/// depends on where on the picture it lands, and no D-pad walk over the two
/// buttons the frame owns can express "this zone". So the pad's cursor is the
/// pointer - the pad layer already moves it with the right stick once a menu
/// owns the pad, because mouse-look is off then - and this is what carries it
/// to the interface. Everything the map does with it is the authored
/// WorldMapFrame code: WorldMapFrame_OnUpdate highlights the zone under
/// GetCursorPosition and names it in the area label, and WorldMapButton's own
/// OnClick is what drills into it.
bool LocalFrameXml::padWorldMapFrame() {
#ifdef WOWEE_SWITCH
    // A field with the keyboard hands the map back to the ordinary panel lane
    // rather than swallowing the presses that belong to the box.
    if(!worldMapOwnsPad() || platform::switchport::keyboardCapturesInput() ||
       platform::switchport::inputTextFocus())return false;
    const auto& io=ImGui::GetIO();
    auto& tree=engine_->widgets();
    const auto* map=worldMapPanel(tree);
    const auto rootId=map->id;
    const bool rootChanged=navigationRoot_!=rootId;
    navigationRoot_=rootId;
    // No control has the pad's focus while the map does, so nothing draws an
    // outline and the carried-icon anchor has nothing to follow.
    focus_=0;padFocus_.clear();
    if(!ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown))padCrossHandled_=false;
    // Every other in-game control is off while the map is up, and this lane is
    // what says so - by answering first, and by answering every frame. Who owns
    // the pad is not asked from here: application.cpp asks panelOpen() once a
    // frame, and the map is one of the panels that answers it.
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight,false) ||
       ImGui::IsKeyPressed(ImGuiKey_Escape,false)){
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceRight);
        ui::noteInterfaceConsumedKey(ImGuiKey_Escape);
        engine_->dispatchMouse(-1,-1,io.DisplaySize.y,{false,false,false});
        if(!panelTreeLive())return true;
        engine_->releaseMouseHover();
        if(panelTreeLive())engine_->executeString(
            "if WorldMapFrame then if HideUIPanel then HideUIPanel(WorldMapFrame) "
            "else WorldMapFrame:Hide() end end");
        return true;
    }
    // The frame the map appeared on: the cursor was somewhere else entirely
    // and a press left over from opening it must not land on a zone.
    if(rootChanged){engine_->dispatchMouse(-1,-1,io.DisplaySize.y,{false,false,false});return true;}
    if(!ImGui::IsMousePosValid(&io.MousePos))return true;
    const bool cross=!padCrossHandled_ && ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown);
    if(cross)ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceDown);
    engine_->dispatchMouse(io.MousePos.x,io.MousePos.y,io.DisplaySize.y,{cross,false,false});
    return true;
#else
    return false;
#endif
}

/// The micro buttons, on a remote realm.
///
/// This is the one part of the bar lane that answers out of the interface alone,
/// and on a remote realm it is the whole of the way in. Everything else in
/// navigateBars() needs the local realm - the contextual Square, the vehicle,
/// the target, the mailbox - and a remote realm has none of it, which is why
/// that lane stops before it. But a remote realm does have the micro buttons,
/// and nothing in kBindings produces TOGGLE_BAGS or TOGGLE_QUESTS, so without
/// this the bags, the spellbook and the quest log are drawn on screen and cannot
/// be opened from the pad at all: the row has to be walked and a panel pressed.
///
/// Shoulders only, and each one on its own, which is the whole of the design:
///
///  - L2 and R2 step the row. Alone they produce no key, because every row in
///    their layers is a face button, and with a face button they are action
///    slots 5-8 and 1-4 - so taking the shoulder without the layer is what keeps
///    all twelve slots reachable. On a remote realm the face buttons are live:
///    Cross jumps, Circle is the right click that interacts, Square is slot 1 and
///    Triangle is target nearest, which is the last of them the most used
///    binding on the pad. None of the four can carry this.
///
///  - R1 opens the chosen button, again alone so it costs no action slot.
///    L1+R1 is chat and L1's own layer is the character keys.
///
/// Both are answered from the shoulder alone, with no face button and no L1
/// down: L1 beside a trigger belongs to the character row, and a face button
/// beside a trigger is an action slot, so a gesture that walks the row and
/// casts at the same time is not one anybody meant. Every row in the L2, R1 and
/// R2 layers is a face button, so a shoulder pressed by itself produces no key
/// and there is nothing here for this to double up with.
///
///  - L3 is free too - it is in no layer but Base - and is deliberately not used.
///    It is the pad's only mode button, so a chord with it is the last shape a
///    player would try, and the on-screen hint is what tells them this one.
bool LocalFrameXml::padMicroMenuLane() {
#ifdef WOWEE_SWITCH
    const auto& io=ImGui::GetIO();
    const auto& pad=platform::switchport::padSnapshot();
    if(!pad.connected || io.WantTextInput)return false;
    const int step=((pad.pressed&ORBIS_PAD_BUTTON_R2)?1:0)-((pad.pressed&ORBIS_PAD_BUTTON_L2)?1:0);
    const bool open=(pad.pressed&ORBIS_PAD_BUTTON_R1)!=0;
    // Answered from the shoulder alone. L1 beside a trigger is the character
    // row and L1+R1 is chat, and a face button held with a shoulder is an
    // action slot - walking the row and casting from the same gesture is not one
    // anybody meant. The same shape the local realm's bar lane uses to keep
    // Square off its own chord.
    constexpr uint32_t kOthers=ORBIS_PAD_BUTTON_L1|ORBIS_PAD_BUTTON_CROSS|
        ORBIS_PAD_BUTTON_CIRCLE|ORBIS_PAD_BUTTON_SQUARE|ORBIS_PAD_BUTTON_TRIANGLE;
    const bool armed=(step || open) && !(pad.buttons&kOthers);
    const bool chosen=padFocus_.lane==ui::LocalPadFocus::Lane::Menus;
    // Nothing pressed and nothing chosen: this frame is not this lane's, and the
    // walk over the panel list below is a scan of thirty names the interface has
    // already answered twice this frame for panelOpen() and the world map.
    if(!armed && !chosen)return false;
    auto& tree=engine_->widgets();
    // A panel on top owns the pad: its own lane has already given L1 and R1 to
    // the scroll wheel and Square to the focused control, so the row would be a
    // second answer to one press. The selection is kept rather than dropped -
    // the local realm's lane keeps its own across an opening for the same
    // reason - so closing the panel puts the pad back on the same icon.
    if(panel(tree))return false;
    bool consumed=false;
    if(armed){
        const auto ids=ui::padMicroButtonRow(tree);
        if(!ids.empty()){
            // An unknown selection lands on the end of the row rather than
            // nowhere, so a first R1 press opens something instead of reading
            // as a dead shoulder.
            uint32_t wanted=ui::LocalPadFocus::step(ids,padFocus_.widget,step);
            if(!wanted)wanted=ids.front();
            padFocus_.select(ui::LocalPadFocus::Lane::Menus,wanted);
            consumed=true;
        }
    }
    if(consumed){
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadL2);
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadR1);
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadR2);
    }
    // The outline outlives the press that chose it, exactly as the bar lane's
    // does: a selection that vanished between two shoulder taps would be a
    // selection nobody could aim at. Read back off the focus, because this frame
    // may be the one that chose it.
    if(padFocus_.lane!=ui::LocalPadFocus::Lane::Menus)return consumed;
    const auto* selected=tree.get(padFocus_.widget);
    if(!ui::padControlVisible(tree,selected)){padFocus_.clear();return consumed;}
    // Drawn before the press is spent, so the frame a panel opens on carries no
    // outline left floating over it.
    drawPadFocus(*selected,tree,tree.uiScale(),io.DisplaySize.y);
    if(consumed && open && selected->enabled){
        // The interface's own OnClick, so the toggle is the authored one - bags,
        // spellbook, quest log, character sheet - and whatever it opens is then
        // reachable by the D-pad like any other panel. Tied to consumed, so a
        // shoulder pressed beside a face button walks nothing and opens nothing
        // and leaves the action slot that same press did fire.
        const uint32_t id=selected->id;
        activatePadControl(id);
        LOG_INFO("[PAD_UI] Micro button opened widget=",id);
    }
    return consumed;
#else
    return false;
#endif
}

bool LocalFrameXml::navigateBars() {
#ifdef WOWEE_SWITCH
    if (platform::switchport::consolePortActive()) return false;
    // Wherever this leaves the selection, that is where the carried icon is
    // drawn. A guard rather than a line before each of the seven returns.
    struct Anchor{LocalFrameXml* self;~Anchor(){self->publishPadCursor();}}anchor{this};
    bool vehicleInput=false;
    if(const auto* realm=realm_?realm_():nullptr)
        if(const auto* player=realm->localPlayer())vehicleInput=player->vehicleGuid!=0;
    // The native vehicle bar also consumes raw chords before FrameXML loads.
    // In particular R2+Cross must not synthesize the legacy key4/exit action.
    //
    // Still keyed on ready(), not on panelTreeLive(): this switch tells the pad
    // layer that FrameXML's own hotbars own the raw shoulders, Square and
    // Triangle in the world. That is only true once the bar lane below is
    // actually running, and it answers out of the local realm (target_, vehicle,
    // nearby mailbox), so turning it on for a remote realm would take Triangle
    // away from TARGETNEAREST and Square away from action slot 1 to hand them
    // to lanes that answer out of `realm_` and have none.
    platform::switchport::setInputActionBars(ready() || vehicleInput);
    if(!panelTreeLive() || platform::switchport::keyboardCapturesInput() || platform::switchport::inputTextFocus())return false;
    // A released spirit's Square is a corpse-reclaim request before any
    // action bar, spell cursor, mailbox, NPC or combat interaction. Mark both
    // raw and mapped actions consumed so the overlay cannot send it twice.
    // Nothing to guard: the answer comes out of `realm_`, which a remote realm
    // has not got, so this branch is already only a local realm's.
    if(auto* realm=realm_?realm_():nullptr) {
        if(const auto* player=realm->localPlayer();player && player->dead) {
            padFocus_.clear();
            const auto& deathPad=platform::switchport::padSnapshot();
            if(player->ghost && deathPad.connected &&
               (deathPad.pressed&ORBIS_PAD_BUTTON_SQUARE) &&
               !(deathPad.pressed&ORBIS_PAD_BUTTON_TRIANGLE)) {
                realm->reclaimCorpse();
                ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceLeft);
                ui::noteInterfaceConsumedKey(ImGuiKey_1);
                return true;
            }
            // Menus/world map remain usable, but stale bar focus cannot cast.
            if(padWorldMapToggle() || padWorldMapFrame())return true;
            return false;
        }
    }
    // Circle cancels a carried reference before closing a panel. Bag contents
    // stay owned by inventory; cancelling never destroys the item. A local
    // realm's lane, and unlike the reclaim above it needs the guard spelled
    // out: what it asks about is the cursor, which a remote realm has too, and
    // on a remote realm Circle is right click - interact, which must not be
    // turned into a cancel.
    if(ready() && carrying(engine_) && (platform::switchport::padSnapshot().pressed&ORBIS_PAD_BUTTON_CIRCLE)) {
        engine_->executeString("if ClearCursor then ClearCursor() end");
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceRight);
        ui::noteInterfaceConsumedKey(ImGuiKey_Escape);
        padFocus_.clear();return true;
    }
    // Before the bars, and before the panel lane the caller runs after this
    // one: the map's button has to work from wherever the player is, and while
    // the map is up nothing else may read the pad.
    //
    // The map is one of kPadPanels and the addon engine draws it like any other,
    // so it is reached above the local realm's gate rather than behind it: a
    // remote realm has the map and none of the bridge, and with the map's own
    // reads behind that gate Minus did nothing there at all.
    if(padWorldMapToggle())return true;
    if(padWorldMapFrame())return true;
    // Everything below is the bar lane: it selects the original interface's
    // action buttons, answers Square out of the local realm's contextual action,
    // and stands down for its vehicle, target and mailbox. None of that exists
    // on a remote realm, and setInputActionBars above is still keyed on this
    // same answer, so the lane stops here.
    //
    // Except for the one part of it that does not: the walk along the micro
    // buttons, which answers out of the interface alone. That is handed to
    // padMicroMenuLane instead of being dropped, because on a remote realm it is
    // the only way to reach its own bags, spellbook or quest log - see there for
    // why it is bound to shoulders that are pressed on their own.
    if(!ready())return padMicroMenuLane();
    const auto& io=ImGui::GetIO();const auto& pad=platform::switchport::padSnapshot();
    if(!pad.connected || io.WantTextInput)return false;
    auto& tree=engine_->widgets();
    const auto visible=[&](const ui::Widget* w){return w && w->visible && w->alpha>.001f &&
        w->rectW>0 && w->rectH>0 && shown(tree,w);};
    const auto* top=panel(tree);
    const bool modal=top && (ui::padModalPanel(top->name));
    if(modal){padFocus_.clear();return false;}
    // The vehicle input bridge selects the original VehicleMenuBar buttons
    // (or its fallback) and owns shoulders/contextual Square in the world.
    // Open panels keep their existing navigation and close bindings.
    if(!top)if(const auto* realm=realm_?realm_():nullptr)
        if(const auto* player=realm->localPlayer();player && player->vehicleGuid){padFocus_.clear();return false;}
    // Triangle target selection releases the bar cursor. While a world unit is
    // targeted the shoulders cannot steal Square back from talk/attack.
    const uint64_t targetGuid=target_?target_():0;
    // Back releases a bar selection without changing the unit. A friendly
    // target must keep its talk action even after this press.
    if(!top && targetGuid && (pad.pressed&ORBIS_PAD_BUTTON_CIRCLE)) {
        padFocus_.clear();
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceRight);
    }
    bool nonCombatTarget=false;
    if(const auto* realm=realm_?realm_():nullptr)
        for(const auto& npc:realm->npcs())if(npc.guid==targetGuid){nonCombatTarget=!npc.hostile || npc.dead;break;}
    // A nearby mailbox owns contextual Square unless an enemy or explicitly
    // selected menu icon owns the action. Old spell focus must not hide mail access.
    if(!top && !carrying(engine_) && (!targetGuid || nonCombatTarget) &&
       padFocus_.lane!=ui::LocalPadFocus::Lane::Menus &&
       !(pad.pressed&(ORBIS_PAD_BUTTON_L2|ORBIS_PAD_BUTTON_R2))) {
        if(const auto* realm=realm_?realm_():nullptr)
            if(const auto* player=realm->localPlayer();player && (player->vehicleGuid || realm->nearbyGameObject() || game::nearbyLocalMailbox(realm->content(),*player))) {
                padFocus_.clear();return false;
            }
    }
    if(!carrying(engine_) && ui::localTargetOwnsShoulders(targetGuid,top!=nullptr,(pad.pressed&ORBIS_PAD_BUTTON_TRIANGLE)!=0,nonCombatTarget)) {
        padFocus_.clear();return false;
    }
    const bool dpad=(pad.pressed&(ORBIS_PAD_BUTTON_UP|ORBIS_PAD_BUTTON_DOWN|ORBIS_PAD_BUTTON_LEFT|ORBIS_PAD_BUTTON_RIGHT))!=0;
    const bool holding=carrying(engine_);
    if(top && dpad){
        // From icon focus into the opened panel - but while carrying, the two
        // are one navigation space rather than two lanes: the panel lane below
        // treats the bars as eligible too, so handing it the button the bar
        // selection was on lets the D-pad walk off the bar and back onto it. A
        // spell lifted in the spellbook could otherwise never reach a slot.
        if(holding && padFocus_.lane==ui::LocalPadFocus::Lane::Actions)focus_=padFocus_.widget;
        padFocus_.clear();
    }
    const int actions=(top && !holding)?0:
        ((pad.pressed&ORBIS_PAD_BUTTON_R1)?1:0)-((pad.pressed&ORBIS_PAD_BUTTON_L1)?1:0);
    const int menus=((pad.pressed&ORBIS_PAD_BUTTON_R2)?1:0)-((pad.pressed&ORBIS_PAD_BUTTON_L2)?1:0);
    // Opening a panel through an action (for example talking to a quest NPC)
    // hands Square over to that panel. L1/R1 now scroll the open panel unless
    // carrying. Menu-icon ownership is retained so Square toggles it.
    // Not while carrying: the bar is the destination then, and taking the
    // selection away because the spellbook opened is taking away the target.
    if(top && top->id!=navigationRoot_ && !actions && !menus && !holding &&
       padFocus_.lane==ui::LocalPadFocus::Lane::Actions)padFocus_.clear();
    bool consumed=false;
    if(actions || menus){
        std::vector<uint32_t> ids;
        if(menus){
            // The shared row, walked in the order they are on screen rather than
            // the order they are named - see ui::padMicroButtonRow for why the
            // bag bar's authored order is the wrong one to step in.
            ids=ui::padMicroButtonRow(tree);
        }else{
            for(const char* prefix:{"ActionButton","MultiBarBottomLeftButton","MultiBarBottomRightButton",
                "MultiBarRightButton","MultiBarLeftButton"})for(int i=1;i<=12;++i){
                const auto name=std::string(prefix)+std::to_string(i);
                if(const auto* w=tree.findByName(name);visible(w))ids.push_back(w->id);
            }
        }
        if(!ids.empty())padFocus_.select(menus?ui::LocalPadFocus::Lane::Menus:ui::LocalPadFocus::Lane::Actions,
            ui::LocalPadFocus::step(ids,padFocus_.widget,menus?menus:actions));
        if(actions){ui::noteInterfaceConsumedKey(ImGuiKey_GamepadL1);ui::noteInterfaceConsumedKey(ImGuiKey_GamepadR1);}
        if(menus){ui::noteInterfaceConsumedKey(ImGuiKey_GamepadL2);ui::noteInterfaceConsumedKey(ImGuiKey_GamepadR2);}
        consumed=true;
    }
    const auto* selected=tree.get(padFocus_.widget);
    if(!visible(selected)){padFocus_.clear();return consumed;}
    drawPadFocus(*selected,tree,tree.uiScale(),io.DisplaySize.y);
    if((pad.pressed&ORBIS_PAD_BUTTON_CROSS) && !(pad.pressed&ORBIS_PAD_BUTTON_TRIANGLE) &&
       padFocus_.lane==ui::LocalPadFocus::Lane::Actions && !actions && !menus){
        // Cross is pick up / put down on the bars as it is inside a panel.
        // Empty cursor picks up; carrying replaces this slot and clears the cursor.
        //
        // Never on the frame the lane was entered. Cross is a world button too,
        // and a shoulder and a face button pressed together is a thing hands do;
        // taking an action off the bar on that combination would be a gesture
        // nobody made. The lane must be selected, and then held for a frame.
        const auto id=selected->id;const auto name=selected->name;
        padPickup(name);
        padCrossHandled_=true;
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceDown);
        LOG_INFO("[PAD_UI] Cross pick up/put down on bar widget=",id);
        return true;
    }
    if((pad.pressed&ORBIS_PAD_BUTTON_SQUARE) && !(pad.pressed&ORBIS_PAD_BUTTON_TRIANGLE)){
        // Only the explicitly selected bar owns this activation. D-pad
        // navigation, or a newly opened quest, clears that ownership above.
        const auto id=selected->id;
        if(selected->enabled){
            // Invoke the real button, including its authored bag/panel toggle
            // and action-slot mapping, not a second native menu implementation.
            const std::string lookup="local b=_G['"+selected->name+"']; ";
            if(padFocus_.lane==ui::LocalPadFocus::Lane::Actions)
                engine_->executeString(lookup+"if b then local slot=b.action or (b.GetAttribute and b:GetAttribute('action')) or b:GetID(); if type(slot)=='number' and UseAction then UseAction(slot) end end");
            else activatePadControl(id);
            LOG_INFO("[PAD_UI] Square activated widget=",id);
        }
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceLeft);
        return true;
    }
    return consumed;
#else
    return false;
#endif
}

bool LocalFrameXml::toggleGameMenu() {
    if (!ready()) return false;
    return engine_->executeString(ui::kToggleLocalGameMenuLua);
}

bool LocalFrameXml::panelOpen() const {
    // Under ConsolePort this used to answer false unconditionally, because the
    // F-key layer was assumed to carry its own panels. The client's own menus
    // draw there too now - the hub opens the plain FrameXML panels - and the
    // pad has to know a panel is up so it walks the panel instead of firing
    // the action slot behind it.
    return panelTreeLive() && panel(engine_->widgets());
}
bool LocalFrameXml::navigate() {
    // Same guard as the bar lane: every exit leaves the carried icon where the
    // focus ended up, and there are a dozen of them.
    struct Anchor{LocalFrameXml* self;~Anchor(){self->publishPadCursor();}}anchor{this};
    // Unconditionally, and before any early return: a press spent on a pickup
    // stays claimed only for as long as the button is held, and the frame that
    // released it may well be one where nothing is focused at all.
    if(!ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown))padCrossHandled_=false;
    // Whether a panel owns the pad is not decided here. application.cpp asks
    // panelOpen() every frame and tells the pad layer, because this function is
    // reached only when the cursor is not over one of this client's own windows
    // and a panel closed behind the cursor's back used to leave the answer
    // standing for as long as nothing came back here to take it back.
    auto* root=panelTreeLive()?panel(engine_->widgets()):nullptr;
    if(!root){focus_=0;navigationRoot_=0;return false;}
#ifdef WOWEE_SWITCH
    if(platform::switchport::keyboardCapturesInput() || platform::switchport::inputTextFocus())return false;
#endif
    const auto rootId=root->id;
    // Read before anything can run Lua: the tree owns a vector and a callback
    // reallocating it leaves this pointer dangling. A modal owns the pad
    // outright - the delete confirmation this file raises is one, and its Yes
    // has to stay reachable rather than being read as another press to let go.
    const bool modalRoot=ui::padModalPanel(root->name);
    const bool rootChanged=navigationRoot_!=rootId;
    navigationRoot_=rootId;
    if(modalRoot)padFocus_.clear();
    auto& tree=engine_->widgets();const auto& io=ImGui::GetIO();
    if(rootChanged){
        focus_=0;
        // A press opening a dialog belongs to the preceding screen. Keep it
        // consumed through release so holding Cross cannot accept the quest.
        if(ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown))padCrossHandled_=true;
        engine_->dispatchMouse(-1,-1,io.DisplaySize.y,{false,false,false});
        if(!panelTreeLive())return true;
    }
    // Carrying makes the action bars part of the open panel's navigation space.
    // They are not descendants of it, so without this the D-pad could never
    // leave the spellbook and a spell picked up there had nowhere to go. Only
    // while carrying: with an empty cursor the bars belong to their own lane,
    // where a shoulder press selects them and Square casts. And never under a
    // modal, which owns the pad outright - see modalRoot.
    const bool holding=carrying(engine_) && !modalRoot;
    const auto controlPoint=[&](const ui::Widget* w){
        return ui::padControlPoint(tree,w,io.DisplaySize.x/tree.uiScale(),io.DisplaySize.y/tree.uiScale());
    };
    const auto eligible=[&](const ui::Widget* w){
        // Reject non-controls before walking ancestors in a large FrameXML tree.
        if(!w || !w->visible || !w->enabled || !w->mouseEnabled || w->alpha<=.001f)return false;
        if(w->objectType!="Button" && w->objectType!="CheckButton" &&
           w->objectType!="Slider" && w->objectType!="EditBox")return false;
        const auto* active=tree.get(rootId);
        return w && active && ui::padPanelAllows(tree,*active,*w,
            holding && padPickupTargetForName(w->name).kind==PadPickupTarget::Kind::Action) && controlPoint(w).has_value();
    };
    const ui::Widget* focused=tree.get(focus_);
    if(!eligible(focused)){
        // Buttons are containers whose child textures draw. drawOrder omits
        // those containers, so navigation must inspect the widget tree itself.
        focused=ui::padInitialControl(tree,rootId,eligible);
        if(focused && rootChanged)LOG_INFO("[PAD_UI] initial dialog focus=",focused->name);
    }
    int dx=0,dy=0;
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadDpadUp))dy=1;
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadDpadDown))dy=-1;
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft))dx=-1;
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight))dx=1;
    if(focused && focused->objectType=="Slider" && dx){
        auto* slider=tree.get(focused->id);
        const float step=slider->sliderStep>0?slider->sliderStep:(slider->barMax-slider->barMin)/100.f;
        const float value=std::clamp(slider->barValue+dx*step,slider->barMin,slider->barMax);
        const auto sliderId=slider->id;slider->barValue=value;
        engine_->callFrameScriptNumber(sliderId,"OnValueChanged",value);
        if (!panelTreeLive()) return true;
        focused=tree.get(sliderId);if (!eligible(focused)) focused=nullptr;dx=0;
    }
    if(focused && (dx || dy)){
        const float x=focused->left+focused->rectW*.5f,y=focused->bottom+focused->rectH*.5f;
        const ui::Widget* best=nullptr;float score=std::numeric_limits<float>::max();
        for(uint32_t id=1;id<tree.size();++id)if(const auto* w=tree.get(id);w!=focused && eligible(w)){
            const float vx=w->left+w->rectW*.5f-x,vy=w->bottom+w->rectH*.5f-y;
            const float along=vx*dx+vy*dy,across=std::abs(vx*dy-vy*dx);
            if(along>1 && along+across*3<score){score=along+across*3;best=w;}
        }
        if(best)focused=best;
    }
    focus_=focused?focused->id:0;
    if(ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight,false) ||
            ImGui::IsKeyPressed(ImGuiKey_Escape,false)){
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceRight);
        ui::noteInterfaceConsumedKey(ImGuiKey_Escape);
        // Only dismiss the active panel. Closing every bag and quest window
        // at once loses the navigation context behind a modal dialog. Names
        // come exclusively from the fixed panel list above.
        const auto* active=tree.get(rootId);
        if(!modalRoot && focused)if(const auto* owner=ui::padOwningPanel(tree,focused))active=owner;
        const std::string name=active?active->name:std::string{};
        focus_=0;
        engine_->dispatchMouse(-1,-1,io.DisplaySize.y,{false,false,false});
        if (!panelTreeLive()) return true;
        engine_->releaseMouseHover();
        if (panelTreeLive() && !name.empty()) {
            if (name.starts_with("StaticPopup")) {
                // Match StaticPopup_EscapePressed's cancellation contract for
                // this topmost popup only: Hide alone skips OnCancel, and some
                // authored dialogs explicitly forbid cancellation via Escape.
                engine_->executeString("local f=_G[\""+name+"\"]; if f and f.hideOnEscape then "
                    "local info=StaticPopupDialogs and StaticPopupDialogs[f.which]; "
                    "if info then if info.OnCancel and not info.noCancelOnEscape then "
                    "info.OnCancel(f,f.data,\"clicked\") end; f:Hide(); "
                    "elseif StaticPopupSpecial_Hide then StaticPopupSpecial_Hide(f) end end");
            } else if (name.starts_with("DropDownList")) {
                engine_->executeString("CloseDropDownMenus()");
            } else {
                engine_->executeString("local f=_G[\""+name+"\"]; if f then if HideUIPanel then HideUIPanel(f) else f:Hide() end end");
            }
        }
        return true;
    }
#ifdef WOWEE_SWITCH
    const auto& rawPad=platform::switchport::padSnapshot();
    if(focused && !rootChanged && !platform::switchport::keyboardCapturesInput() &&
       (rawPad.pressed&ORBIS_PAD_BUTTON_SQUARE) && !(rawPad.pressed&ORBIS_PAD_BUTTON_TRIANGLE) &&
       !ui::interfaceConsumedKey(ImGuiKey_GamepadFaceLeft)){
        const auto id=focused->id;
        activatePadControl(id);
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceLeft);
        LOG_INFO("[PAD_UI] Square panel control=",id);return true;
    }
    // Y on a bag slot is use/equip: the interface's own right click, which is
    // what UseContainerItem answers. A stays the left click (pick up) it always
    // was, so the two buttons mean on the pad what they mean on a mouse. Held
    // off the Square path deliberately - that one is the durable activate.
    if(focused && !rootChanged && !platform::switchport::keyboardCapturesInput() &&
       (rawPad.pressed&ORBIS_PAD_BUTTON_TRIANGLE) && !(rawPad.pressed&ORBIS_PAD_BUTTON_SQUARE) &&
       padPickupTargetForName(focused->name).kind==PadPickupTarget::Kind::Container){
        const auto* control=tree.get(focused->id);
        if(control){
            const float screenH=io.DisplaySize.y;
            const auto point=ui::padControlPoint(tree,control,io.DisplaySize.x/tree.uiScale(),screenH/tree.uiScale());
            if(point){
                const float x=point->x*tree.uiScale(),y=screenH-point->y*tree.uiScale();
                engine_->dispatchMouse(x,y,screenH,{false,true,false});
                if(panelTreeLive())engine_->dispatchMouse(x,y,screenH,{false,false,false});
                LOG_INFO("[PAD_UI] Y used bag slot=",focused->name);
                return true;
            }
        }
    }
#endif
    // A greeting or a quest: A is confirm here, the button the pad uses on the
    // menus hub, not the pick-up/put-down the world uses. There is nothing to
    // carry in a conversation, so the pickup contract below is the wrong answer
    // and Square was the only way to accept a quest. FrameXML's own press/
    // release dispatch at the focused control, so the authored OnClick runs.
    if (focused && !rootChanged &&
        (root->name == "GossipFrame" || root->name == "QuestFrame") &&
        ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) &&
        !ui::interfaceConsumedKey(ImGuiKey_GamepadFaceDown)) {
        const auto id = focused->id;
        activatePadControl(id);
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceDown);
        LOG_INFO("[PAD_UI] A confirmed dialog control=", id);
        return true;
    }
    // Cross is the pad's own pick up / put down, ahead of the synthetic mouse
    // at the bottom of this function. Each of the three interface calls behind
    // padPickup already does both halves against the cursor, so the one button
    // lifts a bag stack, drops it into another slot swapping with whatever was
    // there, and puts a spell on a bar. Holding a left mouse button at the
    // control instead produced a drag nobody asked for and cancelled the
    // ordinary click, which is why the contract is explicit here.
    if(focused && !rootChanged && ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown,false) &&
       !ui::interfaceConsumedKey(ImGuiKey_GamepadFaceDown)){
        const auto target=padPickupTargetForName(focused->name);
        // Whether this control would take what is being carried: a bag item
        // goes into a bag slot or onto a bar, a spell only onto a bar.
        const bool accepts=target.kind==PadPickupTarget::Kind::Action ||
            (target.kind==PadPickupTarget::Kind::Container && carryingBagItem());
        const auto* activeRoot=ui::padOwningPanel(tree,focused);
        const bool inSlotWindow=activeRoot && padWindowBearsSlots(activeRoot->name);
        bool handled=false;
        if(holding && !accepts && target.kind!=PadPickupTarget::Kind::None){
            // A slot, but not one for this: a spellbook button cannot take an
            // item and a bag square cannot take a spell. The press is spent
            // rather than acted on, so a mis-aim costs nothing - which is what
            // the real client does, and is why it is not a drop.
            LOG_INFO("[PAD_UI] Cross on a slot that cannot take the carried entry; keeping it");
            handled=true;
        }else if(holding && !accepts && !inSlotWindow){
            // Genuinely out of the windows that deal in slots. That is what
            // letting go means - see padDropCarried.
            handled=padDropCarried();
        }else if(!holding && target.kind!=PadPickupTarget::Kind::None){
            const auto id=focused->id;const auto name=focused->name;
            padPickup(name);
            LOG_INFO("[PAD_UI] Cross picked up from control=",id);
            handled=true;
        }else if(accepts){
            const auto id=focused->id;const auto name=focused->name;
            padPickup(name);
            LOG_INFO("[PAD_UI] Cross put down on control=",id);
            handled=true;
        }
        // Anything else - a control that is not a slot, inside a window that
        // has some - keeps the click it always had, so the bag's own close
        // button still closes it while the player is carrying something.
        if(handled){
            padCrossHandled_=true;
            ui::noteInterfaceConsumedKey(ImGuiKey_GamepadFaceDown);
            return true;
        }
    }
    // Shoulder scrolling uses the same clipped hit-test path as a real wheel.
    if(focused && ((ImGui::IsKeyPressed(ImGuiKey_GamepadL1) && !ui::interfaceConsumedKey(ImGuiKey_GamepadL1)) ||
                  (ImGui::IsKeyPressed(ImGuiKey_GamepadR1) && !ui::interfaceConsumedKey(ImGuiKey_GamepadR1)))) {
        const auto focusedId=focused->id;
        const auto point=controlPoint(focused);
        if(!point)return true;
        engine_->dispatchMouseWheel(point->x*tree.uiScale(),point->y*tree.uiScale(),
                                    ImGui::IsKeyPressed(ImGuiKey_GamepadL1)?1:-1);
        ui::noteInterfaceConsumedKey(ImGuiKey_GamepadL1);ui::noteInterfaceConsumedKey(ImGuiKey_GamepadR1);
        // OnMouseWheel can create/reparent/hide controls. WidgetTree owns a
        // vector, so the pointer from before a Lua callback may be dangling.
        if (!panelTreeLive()) return true;
        focused=tree.get(focusedId);
        if (!eligible(focused)) {focus_=0;return true;}
    }
    if(!focused)return false;
    const float scale=tree.uiScale();
    drawPadFocus(*focused,tree,scale,io.DisplaySize.y);
    const auto point=controlPoint(focused);
    if(!point){focus_=0;return true;}
    const float centreX=point->x*scale;
    const float centreY=io.DisplaySize.y-point->y*scale;
    // Pointer mode still uses the real cursor; D-pad navigation chooses this control.
    // The press this frame may already have been spent on a pickup, in which
    // case the button must not also be held down here: a synthetic press at the
    // same control is exactly the accidental drag the contract above replaces.
    const bool crossReleased=ImGui::IsKeyReleased(ImGuiKey_GamepadFaceDown);
    const bool crossDown=!padCrossHandled_ && ImGui::IsKeyDown(ImGuiKey_GamepadFaceDown);
    if(!rootChanged && (crossDown || crossReleased || dx || dy)) {
        engine_->dispatchMouse(centreX,centreY,io.DisplaySize.y,
            {crossDown,false,false});return true;
    }
    // Do not let the generic mouse lane reuse the dialog-opening press.
    return rootChanged || padCrossHandled_;
}
}
