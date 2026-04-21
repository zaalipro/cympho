alias Cympho.Issues
alias Cympho.Comments

{:ok, issue1} = Issues.create_issue(%{
  title: "First Issue",
  description: "This is the first issue in the system",
  status: :backlog,
  priority: :high
})

{:ok, _issue2} = Issues.create_issue(%{
  title: "Second Issue",
  description: "This is the second issue for testing",
  status: :in_progress,
  priority: :medium
})

{:ok, _comment1} = Comments.create_comment(%{
  body: "This is a comment on the first issue",
  author_type: "user",
  author_id: "alice-123",
  issue_id: issue1.id
})

{:ok, _comment2} = Comments.create_comment(%{
  body: "Another comment here",
  author_type: "user",
  author_id: "bob-456",
  issue_id: issue1.id
})

IO.puts("Seeded issues and comments successfully")
