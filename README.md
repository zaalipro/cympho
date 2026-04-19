# Cympho

A Phoenix LiveView application for managing issues with real-time comments.

## Features

- Issue CRUD operations (Create, Read, Update, Delete)
- Issue detail view with status and priority tracking
- Comments on issues
- Real-time updates via PubSub
- LiveView-powered reactive UI

## Setup

```bash
# Install dependencies
mix deps.get

# Create and migrate database
mix ecto.setup

# Start the server
mix phx.server
```

## Testing

```bash
mix test
```

## Architecture

- `Cympho.Issues` - Issue management context
- `Cympho.Comments` - Comment management context
- `CymphoWeb.IssueLive` - LiveView components for issue UI
- Phoenix PubSub for real-time updates
