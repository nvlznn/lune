// Shared helpers for the integration tests (local `supabase start`).

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

export const env = Object.fromEntries(
  execFileSync("supabase", ["status", "-o", "env"], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.match(/^([A-Z_]+)="?(.*?)"?$/))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
export const admin = createClient(env.API_URL, env.SERVICE_ROLE_KEY, { auth: { persistSession: false } });

// A tiny JPEG; Storage checks the declared type, not the pixels.
export const JPEG = Buffer.from(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k=",
  "base64",
);

/** A time zone where the local hour is `hour` right now ("Etc/GMT-8" is UTC+8). */
export function zoneForHour(hour) {
  const offset = ((hour - new Date().getUTCHours() + 36) % 24) - 12;
  return offset === 0 ? "Etc/GMT" : offset > 0 ? `Etc/GMT-${offset}` : `Etc/GMT+${-offset}`;
}

export function psql(sql) {
  return execFileSync("docker", ["exec", "-i", "supabase_db_lune", "psql", "-U", "postgres", "-d", "postgres", "-Atq"], {
    input: sql,
    encoding: "utf8",
  }).trim();
}

export async function rpc(user, fn, args = {}) {
  const { data, error } = await user.client.rpc(fn, args);
  assert.ifError(error);
  return data;
}

/** A signed-in user with a profile, living where the diary is open (22:00) or closed (12:00). */
export async function signUp(name, { open = true } = {}) {
  const email = `${name}-${randomUUID()}@integration.test`;
  const password = randomUUID();
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.ifError(error);
  const client = createClient(env.API_URL, env.ANON_KEY, { auth: { persistSession: false } });
  assert.ifError((await client.auth.signInWithPassword({ email, password })).error);
  const user = { id: data.user.id, client };
  await rpc(user, "save_profile", { p_display_name: name, p_accept_terms: true });
  const username = `${name.toLowerCase()}_${randomUUID().slice(0, 8)}`;
  await rpc(user, "set_username", { p_username: username });
  await rpc(user, "set_time_zone", { p_time_zone: zoneForHour(open ? 22 : 12) });
  return { ...user, username };
}

export async function befriend(a, b) {
  await rpc(a, "add_friend", { p_username: b.username });
  await rpc(b, "respond_friend_request", { p_from_id: a.id, p_accept: true });
}

export function newPath(user) {
  return `${user.id}/${randomUUID()}.jpg`;
}

export function uploadFile(user, path, body = JPEG, contentType = "image/jpeg") {
  return user.client.storage.from("entries").upload(path, body, { contentType, upsert: false });
}

/** Uploads a photo and writes the page for today (or yesterday). Returns the page. */
export async function writePage(user, { daysAgo = 0, text = "A good day." } = {}) {
  const state = await rpc(user, "tonight");
  const day = state.days[daysAgo].day;
  const path = newPath(user);
  assert.ifError((await uploadFile(user, path)).error);
  return rpc(user, "write_entry", { p_day: day, p_storage_path: path, p_text: text, p_taken_at: null });
}

export async function fileExists(path) {
  const [folder, name] = path.split("/");
  const { data, error } = await admin.storage.from("entries").list(folder);
  assert.ifError(error);
  return data.some((f) => f.name === name);
}
