//=============================================================================
// main.js
//=============================================================================
// Standard RPG Maker MV entry point: set up plugins, then start the engine on
// page load. Our embedded host fires window.onload once the core scripts and
// this file have been evaluated (see mruby-mvjs/mrblib/mv.rb).

PluginManager.setup($plugins);

window.onload = function() {
    SceneManager.run(Scene_Boot);
};
