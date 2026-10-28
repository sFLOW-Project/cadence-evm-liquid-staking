CREATE TABLE IF NOT EXISTS "contracts" (
	"address" text NOT NULL,
	"chain_id" integer NOT NULL,
	"starting_block" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "contracts_pkey" PRIMARY KEY("address","chain_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "blocks" (
	"number" integer NOT NULL,
	"hash" text NOT NULL,
	"timestamp" timestamp with time zone NOT NULL,
	"chain_id" integer NOT NULL,
	CONSTRAINT "blocks_pkey" PRIMARY KEY("number","chain_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "events" (
	"id" text PRIMARY KEY NOT NULL,
	"chain_id" integer NOT NULL,
	"block_number" integer NOT NULL,
	"transaction_hash" text NOT NULL,
	"log_index" integer NOT NULL,
	"event" text NOT NULL,
	"data" json NOT NULL,
	"timestamp" timestamp with time zone,
	"processed_at" timestamp with time zone,
	"received_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "requests" (
	"id" text NOT NULL,
	"type" text NOT NULL,
	"version" integer NOT NULL,
	"chain_id" integer NOT NULL,
	"event_id" text NOT NULL,
	"requester" text NOT NULL,
	"status" text NOT NULL,
	"data" json NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "requests_pkey" PRIMARY KEY("id","version")
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "events" ADD CONSTRAINT "events_block_number_chain_id_fkey" FOREIGN KEY ("block_number","chain_id") REFERENCES "public"."blocks"("number","chain_id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "requests" ADD CONSTRAINT "requests_event_id_events_id_fk" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "requests_event_id_uidx" ON "requests" USING btree ("event_id");
