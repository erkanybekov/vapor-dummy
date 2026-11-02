import SwiftUI

struct TodosView: View {
    @Environment(AppModel.self) private var model
    @State private var todos: [Todo] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var total = 0
    @State private var newTitle = ""
    @State private var editing: Todo?
    @State private var error: String?
    @State private var loaded = false

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Новая задача", text: $newTitle)
                            .onSubmit(add)
                        Button(action: add) {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    if loaded && todos.isEmpty {
                        Text("Задач нет. Добавьте первую — она сохранится в Postgres через Vapor API.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(todos) { todo in
                        TodoRow(todo: todo, toggle: { toggle(todo) })
                            .contentShape(Rectangle())
                            .onTapGesture { editing = todo }
                    }
                    .onDelete(perform: delete)

                    if page < totalPages {
                        Button("Загрузить ещё") { Task { await load(page: page + 1) } }
                    }
                } footer: {
                    if total > 0 { Text("Всего: \(total)") }
                }
            }
            .navigationTitle("Задачи")
            .refreshable { await load(page: 1) }
            .task { if !loaded { await load(page: 1) } }
            .sheet(item: $editing) { todo in
                EditTodoView(todo: todo) { updated in
                    replace(updated)
                }
            }
        }
    }

    private func load(page: Int) async {
        do {
            let result = try await model.api.todos(page: page, limit: pageSize)
            todos = page == 1 ? result.todos : todos + result.todos.filter { new in !todos.contains { $0.id == new.id } }
            self.page = page
            totalPages = max(1, result.pagination.totalPages)
            total = result.pagination.total
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        newTitle = ""
        Task {
            do {
                _ = try await model.api.createTodo(title: title, description: nil)
                await load(page: 1)
            } catch {
                newTitle = title
                self.error = error.localizedDescription
            }
        }
    }

    private func toggle(_ todo: Todo) {
        var optimistic = todo
        optimistic.completed.toggle()
        replace(optimistic)
        Task {
            do {
                replace(try await model.api.toggleTodo(id: todo.id))
            } catch {
                replace(todo)
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { todos[$0] }
        todos.remove(atOffsets: offsets)
        total -= removed.count
        Task {
            for todo in removed {
                do {
                    try await model.api.deleteTodo(id: todo.id)
                } catch {
                    self.error = error.localizedDescription
                    await load(page: 1)
                    return
                }
            }
        }
    }

    private func replace(_ todo: Todo) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) { todos[index] = todo }
    }
}

private struct TodoRow: View {
    let todo: Todo
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.completed ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(todo.completed ? "Отметить невыполненной" : "Отметить выполненной")

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .strikethrough(todo.completed)
                    .foregroundStyle(todo.completed ? .secondary : .primary)
                if let description = todo.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EditTodoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let todo: Todo
    let onSaved: (Todo) -> Void

    @State private var title: String
    @State private var details: String
    @State private var error: String?
    @State private var saving = false

    init(todo: Todo, onSaved: @escaping (Todo) -> Void) {
        self.todo = todo
        self.onSaved = onSaved
        _title = State(initialValue: todo.title)
        _details = State(initialValue: todo.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                TextField("Описание", text: $details, axis: .vertical)
                    .lineLimit(3...8)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить", action: save)
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        saving = true
        Task {
            do {
                // An empty description clears it on the server (nil would keep the old one).
                let updated = try await model.api.updateTodo(
                    id: todo.id,
                    changes: .init(title: title.trimmingCharacters(in: .whitespaces), description: details.trimmingCharacters(in: .whitespaces))
                )
                onSaved(updated)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
