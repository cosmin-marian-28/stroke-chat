import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response("Unauthorized", { status: 401 });
    }

    const { convo_id } = await req.json();
    if (!convo_id) {
      return new Response("Missing convo_id", { status: 400 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Verify the caller is a participant using their JWT
    const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) {
      return new Response("Unauthorized", { status: 401 });
    }

    // Use service role for all deletions (bypasses RLS)
    const admin = createClient(supabaseUrl, serviceKey);

    // Verify user is a participant
    const { data: convo } = await admin
      .from("conversations")
      .select("participants")
      .eq("id", convo_id)
      .single();

    if (!convo || !convo.participants.includes(user.id)) {
      return new Response("Forbidden", { status: 403 });
    }

    // 1. Delete all media files in storage under this convo
    const { data: files } = await admin.storage
      .from("chat-media")
      .list(convo_id, { limit: 1000 });

    if (files && files.length > 0) {
      const paths = files.map((f: any) => `${convo_id}/${f.name}`);
      await admin.storage.from("chat-media").remove(paths);
    }

    // 2. Delete placed stickers
    await admin.from("placed_stickers").delete().eq("convo_id", convo_id);

    // 3. Delete all messages
    await admin.from("messages").delete().eq("convo_id", convo_id);

    // 4. Delete the conversation itself
    await admin.from("conversations").delete().eq("id", convo_id);

    // 5. Remove friend relationship for both users
    const [uid1, uid2] = convo.participants;
    await admin.from("friends").delete().eq("user_id", uid1).eq("friend_id", uid2);
    await admin.from("friends").delete().eq("user_id", uid2).eq("friend_id", uid1);

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("nuke-convo error:", e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
