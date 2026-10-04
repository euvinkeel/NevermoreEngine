// this is where we can swap out different implementations of statuh
import { pair as base_statuh_pair, create_world as base_statuh_create_world } from "./baseStatuh";
import { pair as jecs_statuh_pair, create_world as jecs_statuh_create_world } from "./jecsStatuh";

// export const statuh_pair = base_statuh_pair;
// export const statuh_create_world = base_statuh_create_world;
export const statuh_pair = jecs_statuh_pair;
export const statuh_create_world = jecs_statuh_create_world;
