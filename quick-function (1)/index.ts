
import { withSupabase } from "jsr:@supabase/server@^1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const MAX_INIT_DATA_LENGTH = 16_384;
const MAX_STATE_BYTES = 128 * 1024;
const MAX_AUTH_AGE_SECONDS = 3600;
const FUTURE_CLOCK_TOLERANCE_SECONDS = 60;

const encoder = new TextEncoder();

function response(data: unknown, status = 200) {
  return Response.json(data, {
    status,
    headers: corsHeaders,
  });
}

async function hmac(
  key: Uint8Array,
  message: string,
): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  return new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      cryptoKey,
      encoder.encode(message),
    ),
  );
}

function hex(bytes: Uint8Array): string {
  return Array.from(
    bytes,
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

function safeEqualHex(a: string, b: string): boolean {
  if (
    !/^[0-9a-f]{64}$/i.test(a) ||
    !/^[0-9a-f]{64}$/i.test(b)
  ) {
    return false;
  }

  const left = encoder.encode(a.toLowerCase());
  const right = encoder.encode(b.toLowerCase());

  let difference = 0;

  for (let i = 0; i < left.length; i++) {
    difference |= left[i] ^ right[i];
  }

  return difference === 0;
}

async function verifyTelegram(
  initData: string,
  token: string,
) {
  if (
    !initData ||
    initData.length > MAX_INIT_DATA_LENGTH
  ) {
    return null;
  }

  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  const authDateText = params.get("auth_date");
  const userText = params.get("user");

  if (!hash || !authDateText || !userText) {
    return null;
  }

  for (const key of ["hash", "auth_date", "user"]) {
    if (params.getAll(key).length !== 1) {
      return null;
    }
  }

  const authDate = Number(authDateText);

  if (
    !Number.isSafeInteger(authDate) ||
    authDate <= 0
  ) {
    return null;
  }

  const now = Math.floor(Date.now() / 1000);

  if (
    now - authDate > MAX_AUTH_AGE_SECONDS ||
    authDate - now > FUTURE_CLOCK_TOLERANCE_SECONDS
  ) {
    return null;
  }

  params.delete("hash");

  const checkString = [...params.entries()]
    .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");

  // Telegram Web Apps:
  // secret_key = HMAC_SHA256(key="WebAppData", message=bot_token)
  // calculated_hash = HMAC_SHA256(key=secret_key, message=check_string)
  const secretKey = await hmac(
    encoder.encode("WebAppData"),
    token,
  );

  const calculatedHash = hex(
    await hmac(secretKey, checkString),
  );

  if (!safeEqualHex(calculatedHash, hash)) {
    return null;
  }

  try {
    const user = JSON.parse(userText);

    if (
      !user ||
      typeof user !== "object" ||
      !Number.isSafeInteger(user.id) ||
      user.id <= 0
    ) {
      return null;
    }

    return user;
  } catch {
    return null;
  }
}

console.info("quick-function started");

export default {
  fetch: withSupabase(
    { auth: ["publishable", "secret"] },
    async (req, ctx) => {
      if (req.method === "OPTIONS") {
        return new Response(null, {
          status: 204,
          headers: corsHeaders,
        });
      }

      if (req.method !== "POST") {
        return response({ error: "POST required" }, 405);
      }

      try {
        const token = Deno.env.get("TELEGRAM_BOT_TOKEN");

        if (!token) {
          console.error("TELEGRAM_BOT_TOKEN is not configured");
          return response(
            { error: "Server not configured" },
            500,
          );
        }

        let body: unknown;

        try {
          body = await req.json();
        } catch {
          return response({ error: "Invalid JSON body" }, 400);
        }

        if (
          !body ||
          typeof body !== "object" ||
          Array.isArray(body)
        ) {
          return response({ error: "Invalid request body" }, 400);
        }

        const requestBody = body as Record<string, unknown>;

        if (typeof requestBody.initData !== "string") {
          return response(
            { error: "Missing Telegram initData" },
            400,
          );
        }

        const user = await verifyTelegram(
          requestBody.initData,
          token,
        );

        if (!user) {
          return response(
            { error: "Invalid or expired Telegram data" },
            401,
          );
        }

        // Identity comes only from verified Telegram initData.
        const telegramId = user.id;
        const db = ctx.supabaseAdmin;

        if (requestBody.action === "load") {
          const { data, error } = await db
            .from("player_state")
            .select("game_state")
            .eq("telegram_id", telegramId)
            .maybeSingle();

          if (error) {
            console.error("Database read failed:", error.code);
            return response(
              { error: "Database read failed" },
              500,
            );
          }

          return response({
            game_state: data?.game_state ?? null,
          });
        }

        if (requestBody.action === "save") {
          const state = requestBody.state;

          if (
            !state ||
            typeof state !== "object" ||
            Array.isArray(state)
          ) {
            return response({ error: "Invalid state" }, 400);
          }

          let serializedState: string;

          try {
            serializedState = JSON.stringify(state);
          } catch {
            return response({ error: "Invalid state" }, 400);
          }

          if (
            encoder.encode(serializedState).byteLength >
            MAX_STATE_BYTES
          ) {
            return response({ error: "State too large" }, 413);
          }

          const { error } = await db
            .from("player_state")
            .upsert({
              telegram_id: telegramId,
              game_state: JSON.parse(serializedState),
              updated_at: new Date().toISOString(),
            });

          if (error) {
            console.error("Database write failed:", error.code);
            return response(
              { error: "Database write failed" },
              500,
            );
          }

          return response({ ok: true });
        }

        return response({ error: "Unknown action" }, 400);
      } catch (error) {
        console.error(
          "quick-function error:",
          error instanceof Error ? error.message : "Unknown error",
        );

        return response({ error: "Internal server error" }, 500);
      }
    },
  ),
};
