defmodule CymphoWeb.Format do
  @moduledoc """
  Centralized presentation helpers shared across LiveViews.

  Use:
      import CymphoWeb.Format

  These were duplicated across 5+ LiveViews with subtle drift. If you find
  yourself adding a presentation helper used by more than one LiveView,
  add it here instead of redefining it.
  """

  @doc """
  CSS classes for an agent status pill.
  """
  def status_pill_class(:running), do: "border-brand/25 bg-brand/10 text-brand"
  def status_pill_class(:idle), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def status_pill_class(:sleeping), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def status_pill_class(:paused), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def status_pill_class(:error), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def status_pill_class(:active), do: "border-success/25 bg-success/10 text-success"
  def status_pill_class(:terminated), do: "border-border bg-surface text-text-quaternary"
  def status_pill_class(:offline), do: "border-border bg-surface text-text-quaternary"
  def status_pill_class(_), do: "border-border bg-surface text-text-secondary"

  @doc """
  CSS classes for a role-coded avatar background.
  """
  def role_avatar_class(:ceo), do: "bg-brand/15 text-brand"
  def role_avatar_class(:cto), do: "bg-sky-500/15 text-sky-300"
  def role_avatar_class(:engineer), do: "bg-emerald-500/15 text-emerald-300"
  def role_avatar_class(:product_manager), do: "bg-amber-500/15 text-amber-300"
  def role_avatar_class(:designer), do: "bg-fuchsia-500/15 text-fuchsia-300"
  def role_avatar_class(_), do: "bg-subtle text-text-secondary"

  @doc """
  Standard DateTime → human format. Returns "—" for nil.
  """
  def format_datetime(nil), do: "—"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def format_datetime(_), do: "—"
end
