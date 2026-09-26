# Project SaaS — Migration 001–010

**Cập nhật 25/09/2026:** Thiết kế đổi sang năm trạng thái tổng `Chưa bắt đầu`, `Đang thiết kế`, `Chờ khách duyệt`, `Đã duyệt`, `Đã hủy`; lần gửi thêm `Đã hủy`. Trigger đồng bộ theo lần gửi mới nhất: gửi → chờ duyệt, khách yêu cầu sửa → đang thiết kế, duyệt → đã duyệt. Hủy một lần gửi không tự hủy Thiết kế; User có quyền tự đổi trạng thái tổng sang `Đã hủy`. Trạng thái Project không đổi. Đã áp dụng lại 001–010 trên Supabase Local, lint không lỗi, **176 pgTAP** và **1058 HTTP/concurrency** đạt. Xem README để biết trạng thái dữ liệu mẫu.

Bản nháp cài mới, cập nhật ngày **24/09/2026** theo `project_handoff_business_decisions.md` và các quyết định Lead/phân quyền đã chốt trong cuộc trao đổi.

**Đã chạy Supabase Local trên Windows ngày 24/09/2026:** Migration 001–010 từ DB trống thành công, lint không có lỗi. Kết quả trước cập nhật Thiết kế: **157 assertion pgTAP và 1058 kiểm tra tích hợp PASS**. Xem README để biết môi trường, lịch sử thất bại và giới hạn. Bộ này dành cho DB trống; không chạy chồng lên database đã cài thiết kế Sale cũ. Không tạo Migration 011.

**Bản cập nhật ẩn Project:** SQL 002/007/008/009/010 đã thay đổi, migration đã sync, reset/lint, 157 pgTAP và 1058 kiểm tra HTTP/concurrency đạt. Harness đã reset dữ liệu thử nghiệm local sau khi chạy; `db:lint`, `db:test` và `check` đạt khi kiểm tra lại.

Bước kiểm thử gần nhất thêm 199 ca quyền DELETE/phân công/thành viên/Owner-only và 16 ca trạng thái nhiều item đồng thời. Không phát hiện lỗi SQL mới ở các ca này, không sửa migration. Không coi các ca khóa có kiểm soát là chứng minh không có deadlock ở mọi transaction nhiều câu lệnh. API xóa Project/thu hồi assignment nghiệm thu chưa đầy đủ; không tự thêm client DELETE hoặc cascade để bỏ qua các quan hệ bảo vệ.

## Sửa kỹ thuật sau kiểm thử API/Role

`007_functions_rpcs.sql` và `009_rls.sql` sửa lỗi RLS khi Marketing/Sales tạo Lead với `INSERT ... RETURNING` (HTTP `Prefer: return=representation`). Trước sửa, INSERT không RETURNING thành công nhưng có RETURNING báo `42501`: hàm STABLE `can_lead` tra lại bảng không thấy NEW row trong snapshot của statement.

Tách helper private `lead_assignment_scope` kiểm tra active actor và phạm vi phân công. Policy trên hàng Lead dùng helper này sau các kiểm tra tenant/subscription/Permission đã có; `can_lead` của RPC và quan hệ khác vẫn yêu cầu Lead tồn tại. Không nới quyền xem hoặc cho người tạo giữ quyền sau phân công. Helper không được client gọi trực tiếp. Test hồi quy xác nhận deny `lead.view` vẫn chặn SELECT/RETURNING; các kiểm thử workflow và concurrency cũ đều tiếp tục đạt. Đã sync nguồn sang supabase/migrations và kiểm tra hash trước reset.

Các sửa trước đó chỉ thuộc test/config: sửa CTE test ban đầu và tắt analytics local do Vector không kết nối Docker TCP 2375.

## Thứ tự chạy sau khi thiết lập Supabase Local

Dùng tài khoản migration có quyền phù hợp; cần Supabase `auth.users`, `auth.uid()` và `gen_random_uuid()`.

| Migration | Nội dung và thay đổi lần này |
| --- | --- |
| 001_foundation.sql | Giữ nguyên: tenant, User/Role, allow/deny, subscription và counter đã phù hợp |
| 002_leads_sales_projects.sql | Bỏ bảng `sales`, `sale_users`; Lead giữ trạng thái bán hàng và thêm `customer_requirements`; dùng lịch sử `lead_assignments`; Project chỉ lưu `source_lead_id` |
| 003_catalog_quotes.sql | Quote chỉ liên kết `lead_id`; sửa FK, UNIQUE và index tương ứng |
| 004_project_modules.sql | Giữ nguyên: module/snapshot vẫn dùng Quote item/version, không phụ thuộc hồ sơ Sale |
| 005_acceptance_payments_documents_notifications.sql | Bỏ chủ sở hữu Document là Sale; Document thuộc đúng một Project, Lead hoặc Quote |
| 006_cross_table_constraints.sql | Lịch sử áp dụng chứng minh Project và Quote cùng Lead/công ty; giữ kiểm tra phiên bản đã chốt, registry từng áp dụng và lịch sử V1 → V2 → V1 |
| 007_functions_rpcs.sql | Sửa phạm vi Lead; thêm RPC phân công/danh sách người có thể phân công; đổi thành `create_project_from_lead`; sửa áp dụng Quote; giữ các RPC quản trị được bảo vệ |
| 008_triggers.sql | Bỏ trigger của Sale; bảo vệ lịch sử phân công; cấp số Lead/Quote atomically; khóa danh tính/nguồn Lead của Quote; sửa bảo vệ nguồn Project |
| 009_rls.sql | RLS bao phủ 51 bảng public; bỏ quyền/bảng Sale; phân công Lead chỉ qua RPC; Owner/Admin xem dữ liệu nghiệp vụ cùng công ty; vẫn kiểm tra quyền ghi và protected action riêng |
| 010_seeds_defaults.sql | 56 mã quyền (bỏ `project.delete`), ma trận 11 Role đã chốt; giữ 3 gói, 6 nhóm chi phí và settings khởi tạo |

Giữ tên file 002 cũ để tránh làm hỏng thứ tự/tham chiếu bộ bàn giao. Chữ `sales` trong tên file không có nghĩa còn bảng hồ sơ Sale. `project_sales` và Role `sales` vẫn tồn tại vì đại diện **nhân viên Sales**, không phải hồ sơ bán hàng riêng.

## Workflow Lead và phân công

- Marketing/Sales tạo Lead: tên, điện thoại, nguồn và thông tin khách. `customer_requirements` lưu nhu cầu; `notes` lưu ghi chú chăm sóc.
- Trạng thái Lead: Mới tiếp nhận, Đã liên hệ, Đã gửi báo giá, Đàm phán, Thành công, Thất bại. Thành công/Thất bại có thể đổi lại.
- Lead chưa có phân công đang mở: người có `lead.view` cùng công ty xem được.
- Lead có phân công đang mở: chỉ người trong danh sách có `lead.view` xem được. `created_by`, `lead.assign` hoặc thành viên Project không tự mở phạm vi Lead.
- Owner/Admin đang active xem mọi Lead trong công ty, vẫn chịu trạng thái công ty/thuê bao. Ngoại lệ này chỉ dành cho đọc; không vượt quyền ghi/protected action.
- Một Lead có nhiều người phụ trách ngang nhau. Trưởng nhóm phải đưa chính mình vào danh sách để tiếp tục xem cùng nhân viên.
- `lead_assignments` giữ các lần giao/thu hồi; partial UNIQUE `(company_id,lead_id,user_id) WHERE unassigned_at IS NULL` chống trùng người đang phụ trách.
- Thu hồi hết người phụ trách mở lại phạm vi Lead chưa phân công. Phân công lịch sử không cấp quyền xem.
- Không tự tạo assignment cho người tạo Lead. Lead mới bắt đầu chưa phân công.

### RPC phân công và cách gọi

`public.set_lead_assignees(p_company uuid, p_lead uuid, p_users uuid[])` thay thế **toàn bộ danh sách hiện tại** trong một transaction. Truyền cả người muốn giữ và người muốn thêm; mảng rỗng thu hồi tất cả. NULL hoặc phần tử NULL bị từ chối; UUID trùng được gộp.

RPC kiểm tra `lead.assign`, quyền xem và phạm vi Lead hiện tại sau khi khóa Lead; kiểm tra người nhận active/cùng công ty; đóng lần phân công bị gỡ, thêm người mới và ghi audit người thực hiện. Người giữ nguyên không bị tạo lại lịch sử. Trưởng nhóm giao cho A, B và mình bằng một lần gọi, tránh mất quyền sau khi giao người đầu tiên. Nếu không giữ mình, lần gọi hợp lệ vẫn hoàn thành, nhưng các lần truy cập tiếp theo không còn quyền xem Lead đó.

`public.list_lead_assignee_candidates(p_company uuid,p_lead uuid)` chỉ trả `user_id, full_name` của User active cùng công ty, sau khi kiểm tra quyền phân công và phạm vi Lead. Người được cấp riêng `lead.assign` có thể dùng bộ chọn người mà không cần `user.view`; không lộ email, Auth ID hay quyền quản trị User.

Không cấp INSERT/UPDATE/DELETE trực tiếp cho client trên `lead_assignments`. Không xóa lịch sử; danh tính và người/thời điểm kết thúc không được viết lại sau khi đóng.

## Báo giá và Project

- Tạo Quote trực tiếp từ Lead; không có `sale_id` hoặc `source_sale_id` trong schema.
- Dùng `public.create_project_from_lead(p_company,p_lead,p_name,p_project_address,p_has_design,p_has_purchasing,p_has_production,p_has_construction)` thay RPC cũ. Nguồn Lead phải nằm trong phạm vi người gọi, có quyền xem, ở trạng thái Thành công; cần `project.create`, thuê bao ghi và quota.
- Lead chuyển Thành công không tự tạo Project. Một Lead có thể tạo nhiều Project.
- Khi tạo Project, các phân công Lead đang mở với User active và `department='Sales'` được sao chép sang `project_members`/`project_sales`; người tạo Project cũng là member. User thuộc bộ phận khác vẫn có thể được giao Lead nhưng không tự trở thành Project Sales. Sau tạo, hai danh sách độc lập.
- `department='Sales'` là quy ước đã có trong SQL cho điều kiện Project Sales; onboarding phải thiết lập đúng. Không hard-code Role Sales cho quyền phân công Lead.
- `projects.source_lead_id`, `quotes.lead_id` cùng company được bảo vệ bằng FK. UNIQUE `(company_id,id,source_lead_id)` và `(company_id,id,lead_id)` làm đích FK cho lịch sử áp dụng. Không UNIQUE riêng trên Lead nguồn.
- Quote đã chốt bất biến; clone giữ lineage và remap vật liệu chốt. Vật liệu chốt phải thuộc chính item. Tổng thiếu phương án/giá vẫn NULL/TẠM TÍNH.
- Áp dụng V1 → V2 → V1 tạo ba dòng lịch sử; một dòng active mỗi Project. Registry chứng minh phiên bản từng được áp dụng cho chính Project; insert history trước, registry sau trong RPC.
- Nguồn Quote của Mua hàng/Sản xuất/Thi công tiếp tục trỏ tới phiên bản đã chốt từng áp dụng; đổi current không sửa snapshot hoặc contract_value.
- Nghiệm thu hoàn thành Project tiếp tục có FK đến round thuộc đúng Project. Giữ quy tắc round mới nhất, ngày thủ công, pause/cancel, không ép progress=100.
- RLS Quote và tài liệu gắn Lead/Quote tiếp tục xét phạm vi Lead nguồn cùng quyền tương ứng. Thành viên Project không tự xem Lead hoặc toàn bộ Quote của Lead. Không tự mở thông tin khách hàng cho người chỉ có quyền module/Project; frontend phải xử lý dữ liệu Lead bị ẩn khi join. Tài liệu gắn Project xét phạm vi Project riêng.

## Quyền và seed

57 quyền thông thường, bỏ bốn mã `sale.*`. Override User vẫn `deny > allow > Role`; không seed override cho User mới. Ngoại lệ Owner/Admin luôn xem dữ liệu nghiệp vụ được tách khỏi phép kiểm tra quyền ghi; các hành động Owner-only vẫn kiểm tra riêng. Inbox cá nhân vẫn self-only theo thiết kế thông báo.

| Role | Quyền mặc định (dấu `/` mở rộng thành các mã riêng) |
| --- | --- |
| Owner | Toàn bộ 57 quyền thông thường; hành động Owner-only kiểm tra riêng |
| Admin | Toàn bộ 57 quyền thông thường; không vượt bảo vệ Owner/Admin |
| Marketing | `lead.view/create/edit` |
| Sales | `lead.view/create/edit`; `quote.view/create/edit/finalize/export`; `project.view/create`; `catalog.view/create/edit`; `design.view`; `purchasing.view`; `production.view`; `construction.view`; `acceptance.view`; `payment.view`; `document.view/create/edit` |
| Project Manager | `lead.view`; `quote.view/export`; `project.view/create/edit/manage_members`; `catalog.view`; `design.view/create/edit`; `purchasing.view/create/edit`; `production.view/create/edit`; `construction.view/create/edit`; `acceptance.view/assign`; `payment.view`; `financial.view`; `document.view/create/edit`; `activity_log.view`; `user.view`; `report.view/export` |
| Designer | `project.view`; `quote.view`; `catalog.view`; `design.view/create/edit`; `document.view/create/edit` |
| Purchasing | `project.view`; `quote.view`; `catalog.view`; `purchasing.view/create/edit`; `document.view/create/edit` |
| Production | `project.view`; `quote.view`; `catalog.view`; `production.view/create/edit`; `document.view/create/edit` |
| Construction | `project.view`; `quote.view`; `construction.view/create/edit`; `document.view/create/edit` |
| Giám sát | `project.view`; `quote.view`; `design.view`; `purchasing.view`; `production.view`; `construction.view/create/edit`; `acceptance.view/create/edit/assign`; `document.view/create/edit` |
| Kế toán | `project.view`; `quote.view/export`; `purchasing.view`; `production.view`; `construction.view`; `acceptance.view`; `payment.view/create/edit`; `financial.view/edit`; `document.view/create/edit`; `activity_log.view`; `report.view/export` |

Marketing/Sales không có `lead.assign` mặc định. Admin cấp riêng bằng `set_user_permission(company,user,'lead.assign','allow')`, thường cho trưởng nhóm. Cấp quyền này không tự đưa User vào Lead đã giao người khác; người đang có phạm vi và quyền phân công hoặc Owner/Admin phải thêm họ.

Role codes lần lượt: `owner`, `admin`, `marketing`, `sales`, `project_manager`, `designer`, `purchasing`, `production`, `construction`, `supervisor`, `accountant`.

Seed giữ 3 gói: Starter 6.800.000 VND/năm, 20 User/200 Project/20 GiB/grace 7 ngày; Business 16.800.000, 100/1.000/100 GiB/grace 1 tháng lịch; Enterprise 36.800.000, 10.000/10.000/1.000 GiB/grace 1 năm lịch. Business/Enterprise có OneDrive ngoài hệ thống 1.000 GB. Không tạo thuê bao đã mua.

Sáu nhóm chi phí: Nhân công, Vật tư, Vận chuyển, Máy móc, Thuê ngoài, Khác. Settings khởi tạo rỗng, không tự đặt ngưỡng ngân sách/tier.

`seed_company_defaults` khóa company, ghi receipt `agreed_lead_defaults_v2`, cấp đúng ma trận cho Role vừa tạo. Chạy lại không phục hồi quyền đã thu hồi hoặc ghi đè tùy chỉnh. Role mặc định đã tồn tại trước lần seed giữ nguyên quyền/tên; trùng code với Role tùy chỉnh bị từ chối và rollback. Đây là seed cài mới, không phải nâng cấp database đã dùng seed cũ. Company mới nhận defaults qua trigger; không sinh User/Auth/Company demo. Onboarding tạo Company, thuê bao hợp lệ, Auth identity rồi User Owner; User active cần qua quota.

## Kiểm toán đã thực hiện

- Phân tích cú pháp SQL ngoài cùng bằng `pglast`: 10 file, 329 câu lệnh. Không khởi động database.
- Đối chiếu 52 bảng (51 public, 1 private), 118 FK với cột nguồn/đích và PK/UNIQUE tương ứng; FK giữa bảng tenant đều mang company_id. `auth.users` là dependency Supabase bên ngoài.
- Kiểm tra cột trong INSERT, cột trigger UPDATE OF, phạm vi danh sách RLS, RPC grant/revoke, không còn định danh schema/hàm/quyền Sale cũ.
- Đối chiếu đúng 57 quyền và toàn bộ 11 Role với ma trận bàn giao; 001 và 004 không cần thay đổi nội dung.
- Có script tái lập `validation/static_audit.py` (cần `pglast`). Script không kiểm chứng toàn bộ SQL động, nội dung PL/pgSQL, type binding, hành vi trigger/policy hoặc concurrency.

## Kiểm thử PostgreSQL/Supabase Local tiếp theo

1. Chạy toàn bộ từ DB trống; kiểm tra compile/runtime/constraint, function privilege và RLS với authenticated/anon/service role.
2. Hai công ty: chặn mọi FK và RPC khác tenant; kiểm tra inactive User, grace chỉ đọc/export, hết hạn khóa truy cập, deny/allow, bảo vệ Owner/Admin.
3. Lead mới: Marketing/Sales cùng thấy; giao A/B và trưởng nhóm: chỉ danh sách thấy; người tạo không tự giữ quyền; người có lead.assign ngoài danh sách không tự xem/chiếm Lead; thu hồi hết mở lại phạm vi.
4. Phân công đồng thời, mảng rỗng/trùng/NULL, User inactive/khác company, thay cả danh sách, giữ lịch sử, audit và rollback; candidate picker không lộ dữ liệu User ngoài tên/ID hoặc ngoài tenant.
5. Tạo Project từ Lead Thành công và đúng phạm vi; chặn Lead khác công ty/ngoài phạm vi/chưa Thành công; không tự sinh Project; snapshot Project Sales độc lập. Thử đồng thời đổi trạng thái/phân công/quota.
6. Quote V1 → V2 → V1, khác Lead/company, version nháp, vật liệu thuộc item khác, source item/version chưa từng áp dụng cho Project; giữ snapshot và contract_value. Clone remap đúng vật liệu cuối.
7. Nghiệm thu đảo kết quả, xóa round, ngày hoàn thành thủ công, pause/cancel, round khác Project; batch/receipt tăng giảm quanh required quantity và phục hồi trạng thái trước đó.
8. Chạy lại 010 sau khi thu hồi quyền/đổi tên Role hoặc nhóm chi phí: không mất tùy chỉnh. Kiểm tra company mới/cũ, trùng code, khởi tạo đồng thời và rollback.

## Các giới hạn còn lại từ bộ nháp

- Đã kiểm thử DB local như README; các ghi chú “chưa chạy” trong header SQL và phần kiểm toán tĩnh ghi nhận giai đoạn bàn giao ban đầu. Chưa kiểm thử đầy đủ concurrency/API hoặc mọi nhánh nghiệp vụ.
- Chưa có flow đầy đủ cho Auth invitation, provisioning, reset mật khẩu, quản trị Owner-only ngoài RPC hiện có và sửa hồ sơ User/Role. Các bảng được bảo vệ không cho client ghi trực tiếp.
- Chưa có RPC bỏ Quote nội bộ để chuyển Project sang Excel bên ngoài; current NULL vẫn được schema cho phép khi phù hợp lịch sử.
- VAT là free text; công thức finalize chưa diễn giải VAT. Cần xác minh cách hiển thị/tính tổng ở ứng dụng trước khi triển khai.
- `financial.edit` không có `financial.view` có RPC riêng. Những luồng edit-without-view khác có thể cần RPC cụ thể vì PostgreSQL có thể áp dụng SELECT policy khi UPDATE/RETURNING; không nới view để né deny.
- Sau pause/cancel, workflow resume cần xử lý lại trạng thái Nghiệm thu theo quyết định nghiệp vụ. Deadline dispatcher cần scheduler tin cậy; chưa cài cron. Audit hiện có chưa bao phủ mọi thao tác ứng dụng.
- Generic entity IDs trong notification/audit cần guarded writer xác minh tenant; không thể dùng một FK cho nhiều bảng. Không lưu secrets/signed URLs trong log.

## Bổ sung Lead/Project và option tùy chỉnh — 26/09/2026

Migration 011 là thay đổi bổ sung sau khi người dùng chốt các trường mới; 001–010 giữ nguyên byte. Xem phần bổ sung cuối `project_handoff_business_decisions.md` và `BUILD_FLOW_LEAD_FIELDS.md` để biết quyết định, cách dùng và kết quả kiểm thử. `source_2`/`source_3` là văn bản; Nguồn, Loại thực hiện, Loại công trình và Lý do thất bại lấy từ option riêng từng công ty. Option bị bỏ được ẩn, vẫn giữ nguyên trên Lead/Project cũ. `leads.budget` và `project_financials.budget` là một giá trị nhập tay độc lập ở mỗi nơi; không có phân loại dự kiến/thực tế.
