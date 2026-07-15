# Workout Sync Service

> ⚠️ **SUPERSEDED — historical design doc only.** This "planned cloud service"
> was implemented instead as [`../pacerunner-server/`](../pacerunner-server/)
> (TypeScript + Hono + SQLite + MCP, live at `pacerunner.brintontech.com`), which
> ingests workouts, derives analytics, and serves them over MCP. This directory
> is kept for historical context; there is no code here and it is not built or
> deployed. For anything current, see `pacerunner-server/README.md`.

Cloud service and MCP server for aggregating workout data and providing AI-powered training insights through Claude Desktop.

## Status

**SUPERSEDED** — realized as `pacerunner-server/` (see banner above). The rest of
this document is the original, unimplemented plan, retained for history.

## Overview

The Workout Sync Service is a future component of the running-tools ecosystem that will:

1. **Ingest workout data** from iOS HealthKit (exported by iOS app)
2. **Store historical data** in cloud database
3. **Expose MCP server** for Claude Desktop integration
4. **Provide AI-powered insights** through natural language queries

## Architecture (Planned)

```
iOS HealthKit
    ↓
Data Export Service (iOS background process)
    ↓
Cloud API (REST/GraphQL)
    ↓
Cloud Database
    ↓
MCP Server
    ↓
Claude Desktop ← User queries
```

## Key Design Principles

### 1. Independence from PaceRunner

The Workout Sync Service is **architecturally separate** from the PaceRunner app:

- No direct coupling between PaceRunner and cloud service
- PaceRunner works 100% offline (constitution requirement)
- Cloud service consumes HealthKit data independently
- Users can use PaceRunner without ever using the sync service

### 2. Post-Workout Analytics Only

Per the constitution (Principle V: Workout Independence):

- **NEVER** sync data during active workouts
- **NEVER** require network connectivity for workouts
- Data export happens **AFTER** workout completion
- HealthKit is the source of truth, cloud is secondary

### 3. User Control

- Users opt-in to cloud sync
- Users can delete all cloud data at any time
- Users control what data is synced
- Transparent privacy policy

## Planned Features

### Data Ingestion

- [ ] iOS background service to export HealthKit workouts
- [ ] Incremental sync (only new workouts)
- [ ] Retry mechanism for failed uploads
- [ ] Conflict resolution for edited workouts

### Data Storage

- [ ] Workout metadata (distance, duration, average pace)
- [ ] Mile splits with paces and deviations
- [ ] Heart rate data (if available)
- [ ] GPS track data (optional, for mapping)
- [ ] Training trends over time

### MCP Server

The MCP server will expose workout data to Claude Desktop, enabling natural language queries:

**Example Queries**:
- "What was my average pace for long runs this month?"
- "How consistent have my mile splits been in recent races?"
- "Show me my progression on 10-mile runs over the past 3 months"
- "Am I improving my negative split execution?"
- "What's my typical pace deviation on marathon-pace runs?"

**Planned MCP Tools**:
- `get_workout_summary(date_range, workout_type)`
- `get_pace_trends(distance, date_range)`
- `get_mile_splits(workout_id)`
- `analyze_training_consistency(period)`
- `compare_workouts(workout_id1, workout_id2)`

### Analytics & Insights

- [ ] Pace consistency analysis
- [ ] Training volume trends
- [ ] Recovery patterns
- [ ] Race predictor (based on training paces)
- [ ] Injury risk indicators (sudden volume spikes)

## Technology Stack (Proposed)

### Backend
- **Language**: Python 3.11+ or TypeScript/Node.js
- **API Framework**: FastAPI or Express.js
- **Database**: PostgreSQL (for structured workout data)
- **Cache**: Redis (for query performance)
- **Deployment**: Cloud Run, Lambda, or similar serverless

### MCP Server
- **Framework**: MCP SDK (Python or TypeScript)
- **Protocol**: MCP (Model Context Protocol)
- **Deployment**: Standalone service or integrated with API

### iOS Data Export
- **Language**: Swift
- **Framework**: HealthKit
- **Background**: Background Tasks framework
- **Networking**: URLSession with background uploads

## Constitution Compliance

This service adheres to Principle V (Workout Independence, Cloud-Enabled Analytics):

✅ Workout execution operates 100% locally
✅ Cloud sync is asynchronous and non-blocking
✅ Data export happens post-workout only
✅ HealthKit is source of truth
✅ Graceful degradation if cloud unavailable
✅ Analytics separation from workout execution
✅ Future-proof for additional cloud tools

## Privacy & Security

- All data encrypted in transit (HTTPS/TLS)
- All data encrypted at rest
- User authentication required
- No data sold or shared with third parties
- GDPR/CCPA compliant data deletion
- Transparent privacy policy

## Implementation Plan

### Phase 1: Infrastructure
- [ ] Set up cloud project (GCP/AWS/Azure)
- [ ] Database schema design
- [ ] API endpoint structure
- [ ] Authentication system

### Phase 2: Data Ingestion
- [ ] iOS HealthKit export service
- [ ] Cloud API endpoints for workout upload
- [ ] Data validation and storage

### Phase 3: MCP Server
- [ ] MCP server implementation
- [ ] Core query tools
- [ ] Claude Desktop integration testing

### Phase 4: Analytics
- [ ] Trend analysis algorithms
- [ ] Insight generation
- [ ] Natural language query processing

### Phase 5: Polish & Launch
- [ ] Performance optimization
- [ ] Security audit
- [ ] Privacy policy
- [ ] User documentation

## Future Enhancements

- Training plan generation (AI-powered)
- Race strategy recommendations
- Virtual training partner (AI pacing companion)
- Integration with other fitness platforms
- Multi-user training groups
- Coach dashboard

## Related Projects

- **PaceRunner**: [`../pace-runner/`](../pace-runner/) - The iOS/watchOS app that generates workout data

## License

TBD
