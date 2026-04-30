import SwiftUI

struct PlanningLandingView: View {
    let appModel: AppModel

    var body: some View {
        AuthenticationFlowView(appModel: appModel)
            .id(appModel.authenticationFlowID)
    }
}
