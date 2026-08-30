-- ============================================
-- UrbanConnect PostgreSQL Initialization
-- ============================================
-- This script runs when PostgreSQL container starts for the first time
-- It creates extensions and initial database structure

-- Enable UUID extension for generating UUIDs
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable PostGIS for geographic data (for geocoding/maps)
CREATE EXTENSION IF NOT EXISTS "postgis";

-- Enable pg_trgm for full-text search and fuzzy matching
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Create schema for Kratos (separate from app schema)
CREATE SCHEMA IF NOT EXISTS kratos;

-- Grant privileges
GRANT ALL PRIVILEGES ON SCHEMA public TO urbanconnect;
GRANT ALL PRIVILEGES ON SCHEMA kratos TO urbanconnect;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO urbanconnect;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO urbanconnect;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA kratos TO urbanconnect;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA kratos TO urbanconnect;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO urbanconnect;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO urbanconnect;
ALTER DEFAULT PRIVILEGES IN SCHEMA kratos GRANT ALL ON TABLES TO urbanconnect;
ALTER DEFAULT PRIVILEGES IN SCHEMA kratos GRANT ALL ON SEQUENCES TO urbanconnect;

-- Create custom types for enums (will be managed by Prisma later)
DO $$ BEGIN
    CREATE TYPE user_status AS ENUM ('active', 'inactive', 'suspended', 'deleted');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE listing_status AS ENUM ('draft', 'active', 'sold', 'expired', 'deleted');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE post_type AS ENUM ('text', 'image', 'video', 'link', 'poll', 'event');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE comment_type AS ENUM ('post', 'listing', 'reply');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE transaction_status AS ENUM ('pending', 'completed', 'cancelled', 'refunded');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Create indexes for commonly queried columns (Prisma will add more)
-- Note: Prisma migrations will create the actual tables
-- This script just sets up the database foundation

-- Log successful initialization
DO $$
BEGIN
    RAISE NOTICE 'UrbanConnect database initialized successfully';
    RAISE NOTICE 'Extensions enabled: uuid-ossp, postgis, pg_trgm';
    RAISE NOTICE 'Custom types created for enums';
    RAISE NOTICE 'Ready for Prisma migrations';
END $$;
