import SwiftUI

extension AliasStore {
    func showLoginNotifications(_ requested: SSHAlias? = nil) {
        guard let entry = requested ?? current, entry.canSSH, !entry.isQuickConnection else { error = "Выбери сохранённую SSH-запись."; return }
        guard loginNotifications?.busy != true else { error = "Дождись завершения действия с уведомлениями или останови его."; return }
        do {
            let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config.url)
            let profile = profiles.active, configuration = config.url, key = entry.favoriteID
            loginNotifications?.close()
            loginNotifications = LoginNotificationModel(entry: prepared, title: title(entry), config: configuration) { [weak self] in
                guard let self, !self.endingWorkspace, self.profiles.active == profile, self.config.url == configuration else { return nil }
                return self.profileEntries.first { $0.favoriteID == key }
            }
        } catch { self.error = error.localizedDescription }
    }
}
