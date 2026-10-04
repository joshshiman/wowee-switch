#!/usr/bin/env python3
"""The FrameXML pad lanes must be gated on the interface, not on the local realm.

A remote realm draws the bags, spellbook, quest log, character sheet, vendor,
game menu and world map through the ordinary addon engine and never installs the
local realm's Lua bridge, so the five pad lanes used to answer "nothing to
drive" on the one realm the release has to work on. This reads the sources and
asserts the wiring, because the regression is entirely in which question each
of those functions asks.

And the last of that gap: navigation is not opening. Nothing in kBindings
produces TOGGLE_BAGS or TOGGLE_QUESTS, so the micro buttons have to be reachable
from the pad on a remote realm or the panels they open stay unreachable. This
asserts the lane that walks them, and that it is built out of controls nothing
in-world needs.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
input_cpp = (ROOT / 'src/addons/local_framexml_input.cpp').read_text()
bridge_cpp = (ROOT / 'src/addons/local_framexml.cpp').read_text()
bridge_hpp = (ROOT / 'include/addons/local_framexml.hpp').read_text()
nav_hpp = (ROOT / 'include/ui/framexml_pad_navigation.hpp').read_text()
prepare_cpp = (ROOT / 'src/core/application_local_realm.cpp').read_text()
application_cpp = (ROOT / 'src/core/application.cpp').read_text()


def body(source, signature):
    """The whole of the function whose definition starts at `signature`."""
    start = source.index(signature)
    depth, end = 1, source.index('{', start) + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


# The predicate: the interface, and nothing about a local realm. Naming the two
# frames is deliberate - a local realm's bridge publishes no widget of its own,
# so those two are what a remote realm's tree has to be judged by as well.
live = body(bridge_cpp, 'bool LocalFrameXml::panelTreeLive() const')
assert 'ui::frameXmlActive()' in live and 'ui::padFrameXmlTreeLive(engine_->widgets())' in live, live
for local_only in ('realm_', 'enabled_', 'installed_', 'isLocalExploration'):
    assert local_only not in live, f'panelTreeLive() must not ask about {local_only}'
assert re.search(r'findByName\("MainMenuBar"\)\s*&&\s*tree\.findByName\("PlayerFrame"\)', nav_hpp)
# ready() is still the local bridge, and now says so by delegating.
ready = body(bridge_cpp, 'bool LocalFrameXml::ready() const')
assert 'panelTreeLive()' in ready and 'realm_' in ready and 'enabled_' in ready, ready

# All five gates ask the tree. padWorldMapToggle/padWorldMapFrame reach it
# through worldMapOwnsPad(), and navigateBars() through the lane guard.
assert body(input_cpp, 'bool LocalFrameXml::panelOpen() const').startswith(
    'bool LocalFrameXml::panelOpen() const {return panelTreeLive() &&')
for signature in ('bool LocalFrameXml::activatePadControl(uint32_t id)',
                  'bool LocalFrameXml::worldMapOwnsPad() const',
                  'bool LocalFrameXml::padWorldMapToggle()',
                  'bool LocalFrameXml::padWorldMapFrame()',
                  'bool LocalFrameXml::navigate()'):
    assert 'panelTreeLive()' in body(input_cpp, signature), signature
    assert 'ready()' not in body(input_cpp, signature), signature

# What must stay local-realm-only, and why. setInputActionBars is the one switch
# that takes Triangle away from TARGETNEAREST and Square away from action slot 1,
# and the bar lane below it answers out of realm_ - so on a remote realm neither
# may run, or the pad loses targeting and slot 1 casting to nothing.
bars = body(input_cpp, 'bool LocalFrameXml::navigateBars()')
assert 'platform::switchport::setInputActionBars(ready() || vehicleInput);' in bars
assert bars.count('if(!ready())return ') == 1, 'the bar lane must stop at exactly one gate'
map_toggle = bars.index('if(padWorldMapToggle())return true;')
map_frame = bars.index('if(padWorldMapFrame())return true;')
bar_gate = bars.index('if(!ready())return ')
assert map_toggle < bar_gate and map_frame < bar_gate, 'the world map must be answered above the bar lane gate'
# And it is answered once: padWorldMapToggle reads a raw press bit, so a second
# call in the same frame would toggle the map straight back.
assert bars.count('if(padWorldMapToggle())return true;') == 1
assert bars.count('if(padWorldMapFrame())return true;') == 1
# The local realm's own lanes. The corpse reclaim needs no guard of its own - it
# answers out of realm_, which is empty on a remote realm - so it is written the
# way it always was; the cancel-cursor lane asks about the cursor, which a remote
# realm has as well, so its local-realm gate is spelled out.
assert 'if(auto* realm=realm_?realm_():nullptr) {' in bars, 'the corpse reclaim stays a local realm branch'
assert 'ready() && carrying(engine_)' in bars, 'the cancel-cursor lane is local-realm-only'

# The gap this closes: a remote realm draws the bags, the spellbook and the quest
# log and nothing in kBindings opens them, so the micro buttons have to be
# reachable there. padMicroMenuLane is what makes them reachable, and it answers
# out of the interface alone - asking about the local realm anywhere in it would
# put the whole lane back behind the bridge it was written for.
micro = body(input_cpp, 'bool LocalFrameXml::padMicroMenuLane()')
for local_only in ('ready()', 'realm_', 'target_', 'carrying(', 'padPickup', 'install'):
    assert local_only not in micro, f'padMicroMenuLane must not ask about {local_only}'
assert 'panelTreeLive' not in micro, 'the caller already gated on the tree'
assert 'ui::padMicroButtonRow' in micro, 'the row is the shared one, not a second list'
assert 'ui::LocalPadFocus::step' in micro, 'stepping is the shared machinery'
assert 'activatePadControl' in micro, 'the panel is opened by the interface own OnClick'
# Two shoulders step it and one opens it, each read off the raw pad and each
# alone - so no face button is taken and all twelve action slots stay reachable.
assert micro.count('pad.pressed&ORBIS_PAD_BUTTON_') >= 3, micro
# The four face buttons are live in-world on a remote realm - jump, interact,
# slot 1, target nearest - and none of them can carry this. They may be named,
# but only in the mask of buttons this lane stands down for.
mask = re.search(r'constexpr uint32_t kOthers=(.*?);', micro, re.S).group(1)
assert 'pad.pressed' not in mask and 'pad.buttons' not in mask, micro
for face in ('ORBIS_PAD_BUTTON_CROSS', 'ORBIS_PAD_BUTTON_CIRCLE',
             'ORBIS_PAD_BUTTON_SQUARE', 'ORBIS_PAD_BUTTON_TRIANGLE'):
    assert face in mask, f'{face} must be listed among the buttons this lane stands down for'
    assert face not in micro.replace(mask, ''), \
        f'{face} is live in-world on a remote realm and must not be bound here'
# L1+R1 is chat and L1's layer is the character keys, so a shoulder beside L1 is
# somebody reaching for those.
assert 'ORBIS_PAD_BUTTON_L1' in mask
# The mask gates the press and the opening together: a shoulder beside a face
# button casts its action slot and walks nothing, and it opens nothing.
assert re.search(r'const bool armed=\(step \|\| open\) && !\(pad\.buttons&kOthers\);', micro), micro
assert 'if(consumed && open && selected->enabled)' in micro, micro
# And a frame with neither a press nor a selection is not this lane's, so the
# thirty-name panel walk is not paid again for nothing.
assert re.search(r'if\(!armed && !chosen\)return false;', micro), micro
# The gate hands over rather than dropping the part that is not local-realm-only.
assert 'if(!ready())return padMicroMenuLane();' in bars
assert bars.index('if(!ready())return padMicroMenuLane();') == bar_gate
# Reached from that one line and nowhere else, so a local realm - ready() true -
# runs exactly the lane it ran before this existed.
assert bars.count('padMicroMenuLane()') == 1, 'the lane is called from exactly one place'
assert 'padMicroMenuLane' not in body(input_cpp, 'bool LocalFrameXml::navigate()')
assert 'bool padMicroMenuLane();' in bridge_hpp
# And the local realm's own row reads the same shared list, so the two lanes can
# never walk two different orders of the same bar. The predicate it reads with is
# the one the bar lane had inline, spelled out once in the header.
assert 'ui::padMicroButtonRow(tree)' in bars
assert 'CharacterMicroButton' not in bars, 'the micro button names live in one list'
assert 'kPadMicroButtons' in nav_hpp and 'padMicroButtonRow' in nav_hpp and 'padControlVisible' in nav_hpp

# The hint has to tell the truth about it: L2/R2 step, R1 opens, and neither is
# listed as a plain L2/R2/R1 press doing nothing.
hud = (ROOT / 'src/ui/game_screen_hud.cpp').read_text()
hint = body(hud, 'void drawPadControlHint(bool inWorld, float safeAreaInset)')
for said in ('L2 / R2', 'R1: open'):
    assert said in hint, f'the on-screen hint does not say {said}'
assert 'L3: autorun' in hint and 'R3: camera / cursor' in hint, hint

# toggleGameMenu() runs local GameMenuFrame Lua and is only called from the local
# realm overlay, so it keeps asking the bridge.
assert 'ready()' in body(input_cpp, 'bool LocalFrameXml::toggleGameMenu()')
overlay = (ROOT / 'src/core/application_local_ui.cpp').read_text()
assert 'localFrameXml_.ready()' in overlay and 'localFrameXml_.toggleGameMenu()' in overlay

# The tree reaches the bridge on a remote realm: bindFrameXmlTree runs before the
# isLocalExploration() guard, not after it. Moving it back under the guard is
# exactly the bug this test exists to stop.
prepare = body(prepare_cpp, 'void Application::prepareLocalFrameXml()')
bind = prepare.index('localFrameXml_.bindFrameXmlTree(')
guard = prepare.index('isLocalExploration()')
assert bind < guard, 'the widget tree must be bound before the local realm guard'
assert 'localFrameXml_.install(' in prepare and prepare.index('localFrameXml_.install(') > guard
assert 'void bindFrameXmlTree(LuaEngine& engine);' in bridge_hpp
# bindFrameXmlTree points at the tree and installs no local realm Lua of its own.
assert body(bridge_cpp, 'void LocalFrameXml::bindFrameXmlTree(LuaEngine& e)') == \
    'void LocalFrameXml::bindFrameXmlTree(LuaEngine& e) { engine_=&e; }'

# The pad-ownership bit a0c2a51 moved into Application::render is derived from
# panelOpen() every frame, and panelOpen() now answers on a remote realm - which
# is what makes the D-pad reach ImGui's gamepad navigation there at all. It must
# still be derived, never latched.
render = body(application_cpp, 'void Application::render(')
assert 'platform::switchport::setInputMenuNavigation(' in render
assert re.search(r'setInputMenuNavigation\(\s*platform::switchport::MenuOwner::FrameXml,\s*'
                 r'drawWidgets && localFrameXml_\.panelOpen\(\)\)', render), render
assert 'setInputMenuNavigation' not in input_cpp, 'the bit is derived in render, not set from a pad lane'
# And the same answer has to reach the world-map lane the D-pad competes with.
assert 'WorldMapFrame' in nav_hpp and 'worldMapPanel' in input_cpp

print('PASS FrameXML pad lanes are gated on the interface, not the local realm: '
      'the five gates ask the tree, the bind precedes the local guard, the bar '
      'lane, cancel-cursor and corpse-reclaim stay behind the bridge, and the '
      'micro buttons are reachable on the realm that has no bridge')