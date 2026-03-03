import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const payload = btoa(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const signingInput = `${header}.${payload}`;
  const pem = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\n/g, "");
  const bin = Uint8Array.from(atob(pem), (c: string) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", bin,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key,
    new TextEncoder().encode(signingInput),
  );
  const encodedSig = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${signingInput}.${encodedSig}`,
  });
  const data = await res.json();
  if (!data.access_token) {
    console.error("OAuth token response:", JSON.stringify(data));
    throw new Error(`No access_token from Google OAuth: ${data.error ?? "unknown"}`);
  }
  return data.access_token;
}

Deno.serve(async (req) => {
  try {
    const { recipient_id, msg_type } = await req.json();
    if (!recipient_id) {
      return new Response("Missing recipient_id", { status: 400 });
    }

    let body: string;
    switch (msg_type) {
      case "image":        body = "you got a photo"; break;
      case "video":        body = "you got a video"; break;
      case "voice":        body = "you got a voice message"; break;
      case "gif":          body = "you got a GIF"; break;
      case "sticker":      body = "you got a sticker"; break;
      case "sv":           body = "you got an SV"; break;
      case "locked_image": body = "you got a locked photo"; break;
      default:             body = "you got a message"; break;
    }

    // --- Validate env vars early ---
    const fcmRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!fcmRaw) {
      console.error("FCM_SERVICE_ACCOUNT secret is not set");
      return new Response(
        JSON.stringify({ error: "FCM_SERVICE_ACCOUNT not configured" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    let sa: any;
    try {
      sa = JSON.parse(fcmRaw);
    } catch {
      console.error("FCM_SERVICE_ACCOUNT is not valid JSON");
      return new Response(
        JSON.stringify({ error: "FCM_SERVICE_ACCOUNT is not valid JSON" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!sa.client_email || !sa.private_key || !sa.project_id) {
      console.error("FCM_SERVICE_ACCOUNT missing required fields (client_email, private_key, project_id)");
      return new Response(
        JSON.stringify({ error: "FCM_SERVICE_ACCOUNT missing required fields" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: tokens, error: tokensErr } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", String(recipient_id));

    if (tokensErr) {
      console.error("device_tokens query error:", tokensErr.message);
      return new Response(
        JSON.stringify({ error: tokensErr.message }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!tokens?.length) {
      console.log(`No device tokens for user ${recipient_id}`);
      return new Response(
        JSON.stringify({ sent: 0, reason: "no_tokens" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    console.log(`Found ${tokens.length} token(s) for user ${recipient_id}`);

    const accessToken = (await getAccessToken(sa)).trim();
    let sent = 0;

    for (const { token } of tokens) {
      const fcmRes = await fetch(
        `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${accessToken}`,
          },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: "strochat", body },
              apns: {
                payload: { aps: { sound: "default", badge: 1 } },
              },
              android: {
                notification: { sound: "default" },
              },
            },
          }),
        },
      );

      if (fcmRes.ok) {
        sent++;
      } else {
        const errText = await fcmRes.text();
        console.error(`FCM send failed (${fcmRes.status}) for token ${token.substring(0, 20)}...: ${errText}`);
        // Clean up stale tokens
        if (errText.includes("UNREGISTERED") || errText.includes("INVALID_ARGUMENT")) {
          await supabase.from("device_tokens").delete().eq("token", token);
          console.log(`Deleted stale token ${token.substring(0, 20)}...`);
        }
      }
    }

    console.log(`Push result: ${sent}/${tokens.length} sent`);
    return new Response(
      JSON.stringify({ sent }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("Push function error:", e);
    return new Response(
      JSON.stringify({ error: String(e) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
