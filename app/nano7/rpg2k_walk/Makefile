APP_NAME    := rpg2k_walk
# rpg2k_walk_core.c is the shared engine (app/shared/rpg2k_walk), copied in
# beside this app by scripts/stage_nano7_walk_app.bash -- NanoApps builds an
# app from its own tree, and hb_app.mk resolves SRCS inside the app directory,
# so the core cannot be referenced where it actually lives.
SRCS        := rpg2k_walk.c rpg2k_walk_core.c
RAW_SURFACE := 1
include ../../sdk/hb_app.mk
