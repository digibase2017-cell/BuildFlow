# TÀI LIỆU BÀN GIAO — CÁC QUYẾT ĐỊNH NGHIỆP VỤ ĐÃ CHỐT

**Dự án:** SaaS quản lý dự án cho đơn vị nội thất / thi công nhà ở quy mô nhỏ  
**Mục đích tài liệu:** Bàn giao sang đoạn chat mới trong cùng Project và dùng làm nguồn đối chiếu cho Codex khi cập nhật đồng bộ Migration 001–010 theo các quyết định mới, hoàn thiện SQL, RLS, Functions, Triggers và kiểm thử Supabase/PostgreSQL.

> **Nguyên tắc:** Nếu nội dung trong tài liệu này khác với các đoạn SQL nháp cũ trong chat, ưu tiên tài liệu này. Các Migration 001–010 hiện là **bản nháp chưa được kiểm thử PostgreSQL/Supabase Local và chưa cập nhật theo thay đổi Lead/phân quyền ngày 24/09/2026**.

**Cập nhật quyết định:** 24/09/2026. Workflow Lead và ma trận quyền dưới đây thay thế thiết kế hồ sơ Sale riêng và ma trận đề xuất trước đó.

---

## 1. Thuật ngữ cốt lõi

### Thuật ngữ giao diện và menu — chốt ngày 27/09/2026

- **Menu tổng**: menu ở panel trái.
- **Menu dự án**: menu ở trang dự án.
- **Ô**: một khu dữ liệu trong panel bên phải. Ví dụ: **Ô Thông tin chung**, **Ô Danh sách công việc gần đây**.

Menu tổng gồm đúng các mục sau, theo thứ tự:

| Menu tổng |
| --- |
| Tổng quan |
| Lead |
| Báo giá |
| Dự án |
| Thiết kế |
| Mua hàng |
| Sản xuất |
| Thi công |
| Tài Chính |
| Báo cáo |
| Nhân sự |
| Cài đặt |

Menu dự án gồm đúng các mục sau, theo thứ tự:

| Menu dự án |
| --- |
| Tổng quan |
| Báo giá |
| Thiết kế |
| Mua hàng |
| Sản xuất |
| Thi công |
| Tài Chính |
| Lịch sử |

Chuẩn hóa lỗi gõ “Thiết kết” trong danh sách menu dự án thành “Thiết kế”, thống nhất với menu tổng và tên module hiện có. Danh sách này chốt cấu trúc menu; quyền truy cập và cờ module vẫn theo nghiệp vụ đã chốt. Nghiệm thu và Thanh toán vẫn thuộc mọi Project; vị trí cụ thể trong các ô chưa được chốt ở quyết định menu này.

### Tên trang và luồng điều hướng dự án — chốt ngày 27/09/2026

- Bấm **Dự án** trong **menu tổng** → trang **Danh sách dự án**.
- Bấm **tên dự án** trong Danh sách dự án → trang **Chi tiết dự án > Tổng quan** của dự án đó. **Tổng quan** là mục mở mặc định khi vào Chi tiết dự án.
- Trong Chi tiết dự án, dùng **menu dự án** để chuyển giữa các trang của cùng dự án; cách gọi thống nhất là **Chi tiết dự án > [Tên mục menu dự án]**.

Các tên trang tương ứng:

| Mục menu dự án | Tên trang |
| --- | --- |
| Tổng quan | Chi tiết dự án > Tổng quan |
| Báo giá | Chi tiết dự án > Báo giá |
| Thiết kế | Chi tiết dự án > Thiết kế |
| Mua hàng | Chi tiết dự án > Mua hàng |
| Sản xuất | Chi tiết dự án > Sản xuất |
| Thi công | Chi tiết dự án > Thi công |
| Tài Chính | Chi tiết dự án > Tài Chính |
| Lịch sử | Chi tiết dự án > Lịch sử |

### Thuật ngữ nghiệp vụ

- **Đối tác / Partner** = công ty mua và sử dụng SaaS, lưu tại `companies`.
- **Khách hàng / Customer** = khách cuối của Đối tác, **không có bảng `customers` riêng**; thông tin Khách hàng chỉ lưu trong `leads`.
- **User** = nhân viên của Đối tác.
- **Role** = vai trò phân quyền mặc định của User.
- **Permission** = quyền thao tác cụ thể.
- **Project** = dự án phát sinh từ Lead.
- **Sales** = nhân viên bán hàng; không có hồ sơ Sale riêng. Lead chứa cả thông tin khách hàng và quá trình chăm sóc.

Mọi bảng nghiệp vụ phải có `company_id` và được bảo vệ tenant-safe bằng khóa ngoại/RLS phù hợp.

---

# 2. ROLE & PERMISSION — QUYẾT ĐỊNH MỚI NHẤT

## 2.1. User có một Role chính

Mô hình hiện tại đang dùng:

`users.role_id -> roles -> role_permissions -> permissions`

User không phải gắn lại toàn bộ Permission khi tạo tài khoản. Khi tạo User, Đối tác chỉ cần chọn Role chính.

## 2.2. Cho phép Permission riêng trên từng User

**ĐÃ CHỐT phương án B:** ngoài Permission kế thừa từ Role, Owner/Admin được phép **cấp thêm hoặc thu hồi Permission riêng cho từng User**, kể cả Permission vốn đến từ Role.

Bảng dự kiến: `user_permissions`.

Mỗi cặp `(company_id, user_id, permission_id)` có tối đa một override riêng:

- `effect = 'allow'` → cấp riêng Permission cho User.
- `effect = 'deny'` → thu hồi riêng Permission khỏi User.
- Không có bản ghi → User kế thừa Permission từ Role.

### Thứ tự tính quyền hiệu lực

1. Nếu `user_permissions = deny` → **Không có quyền**.
2. Nếu `user_permissions = allow` → **Có quyền**.
3. Nếu không có override → dùng `role_permissions`.
4. Sau đó vẫn phải kiểm tra thêm:
   - User còn active hay không.
   - Cùng `company_id`.
   - Có quyền truy cập Project/bản ghi tương ứng hay không.
   - Trạng thái thuê bao/quota có cho phép ghi dữ liệu hay không.

Ví dụ:

- Role Giám sát có `acceptance.edit`, nhưng User A bị `deny` riêng → A không được sửa Nghiệm thu.
- Role Designer không có `acceptance.edit`, nhưng User B được `allow` riêng → B được sửa Nghiệm thu trong các Project B được phép truy cập.

## 2.3. Không có `user_permissions` mặc định cho User mới

User mới chỉ kế thừa Role. `user_permissions` chỉ lưu **ngoại lệ**.

Không tạo hàng chục bản ghi Permission riêng cho mỗi User mới.

## 2.4. Owner/Admin là Role được bảo vệ

Có 11 Role mặc định chính xác:

1. Owner
2. Admin
3. Marketing
4. Sales
5. Project Manager
6. Designer
7. Purchasing
8. Production
9. Construction
10. Giám sát
11. Kế toán

Đối tác có thể tạo Role tùy chỉnh.

### Admin được phép

Admin có toàn quyền với **Role thông thường**:

- Tạo Role mới.
- Sửa Role thông thường, kể cả Role mặc định không phải Owner/Admin.
- Cấp/thu hồi bất kỳ **Permission thông thường** nào cho Role thông thường.
- Cấp/thu hồi Permission riêng cho User thông thường.
- Gán Role thông thường cho nhân viên.

### Admin không được phép

- Tạo Owner hoặc Admin mới.
- Cấp Role Owner/Admin cho User.
- Sửa, hạ cấp hoặc vô hiệu hóa Owner/Admin khác.
- Tự biến mình thành Owner.
- Reset mật khẩu Owner.
- Dùng `user_permissions` hoặc `role_permissions` để vượt qua các hành động quản trị đặc biệt được bảo vệ.

Các hành động Owner-only/protected **không được biểu diễn thành Permission thông thường có thể grant tùy ý**.

## 2.5. Role Giám sát và Nghiệm thu

**Quyết định mới nhất:** Role **Giám sát** mặc định có đủ 4 Permission:

- `acceptance.view`
- `acceptance.create`
- `acceptance.edit`
- `acceptance.assign`

Nhưng đây chỉ là **mặc định có thể thay đổi**.

Owner/Admin có thể:

- Thu hồi từng Permission khỏi Role Giám sát.
- Thu hồi riêng từng Permission khỏi một User Giám sát.
- Cấp các Permission Nghiệm thu cho Project Manager, Designer hoặc Role tùy chỉnh.

Nghiệm thu **không bị hard-code theo Role Giám sát**.

## 2.6. Danh sách Permission đã thống nhất

Bộ Permission sau khi bỏ 4 mã `sale.*` và bỏ `project.delete` gồm **57 mã**. Ký hiệu `/` dưới đây là cách viết gọn các mã riêng biệt:

- `lead.view/view.all/create/edit/delete/assign`
- `quote.view/create/edit/delete/finalize/export`
- `project.view/create/edit/manage_members`
- `catalog.view/create/edit/delete`
- `design.view/create/edit`
- `purchasing.view/create/edit`
- `production.view/create/edit`
- `construction.view/create/edit`
- `acceptance.view/create/edit/assign`
- `payment.view/create/edit/delete`
- `financial.view/edit`
- `document.view/create/edit/delete`
- `activity_log.view`
- `user.view/create/edit`
- `role.view/create/edit`
- `settings.view/edit`
- `report.view/export`

## 2.7. Ma trận Permission mặc định đã chốt

Mỗi mã dạng `module.view/create/edit` được mở rộng thành ba Permission độc lập. Quyền không liệt kê không được cấp mặc định. Ma trận là mặc định khởi tạo; Role thông thường và quyền riêng User vẫn có thể được Owner/Admin điều chỉnh theo mục 2.2–2.4.

| Role | Permission mặc định |
| --- | --- |
| Owner | Toàn bộ 57 Permission thông thường; các hành động Owner-only được kiểm tra riêng |
| Admin | Toàn bộ 57 Permission thông thường; vẫn bị giới hạn bởi các hành động được bảo vệ ở mục 2.4 |
| Marketing | `lead.view/create/edit` |
| Sales | `lead.view/create/edit`; `quote.view/create/edit/finalize/export`; `project.view/create`; `catalog.view/create/edit`; `design.view`; `purchasing.view`; `production.view`; `construction.view`; `acceptance.view`; `payment.view`; `document.view/create/edit` |
| Project Manager | `lead.view`; `quote.view/export`; `project.view/create/edit/manage_members`; `catalog.view`; `design.view/create/edit`; `purchasing.view/create/edit`; `production.view/create/edit`; `construction.view/create/edit`; `acceptance.view/assign`; `payment.view`; `financial.view`; `document.view/create/edit`; `activity_log.view`; `user.view`; `report.view/export` |
| Designer | `project.view`; `quote.view`; `catalog.view`; `design.view/create/edit`; `document.view/create/edit` |
| Purchasing | `project.view`; `quote.view`; `catalog.view`; `purchasing.view/create/edit`; `document.view/create/edit` |
| Production | `project.view`; `quote.view`; `catalog.view`; `production.view/create/edit`; `document.view/create/edit` |
| Construction | `project.view`; `quote.view`; `construction.view/create/edit`; `document.view/create/edit` |
| Giám sát | `project.view`; `quote.view`; `design.view`; `purchasing.view`; `production.view`; `construction.view/create/edit`; `acceptance.view/create/edit/assign`; `document.view/create/edit` |
| Kế toán | `project.view`; `quote.view/export`; `purchasing.view`; `production.view`; `construction.view`; `acceptance.view`; `payment.view/create/edit`; `financial.view/edit`; `document.view/create/edit`; `activity_log.view`; `report.view/export` |

- Marketing chỉ có ba quyền Lead mặc định; không có `document.view/create/edit` hoặc `report.view`.
- Marketing và Sales không có `lead.assign` mặc định. Admin cấp riêng quyền này cho từng User, thường là trưởng nhóm Sales, qua `user_permissions` với `effect = 'allow'`. Không cần tạo Role trưởng nhóm riêng. Owner vẫn có quyền quản trị theo mục 2.2.
- Sales có đủ `catalog.view/create/edit`; Purchasing chỉ có `catalog.view`.
- Giám sát có thêm `construction.create/edit` và giữ đủ bốn quyền Nghiệm thu.
- Không seed hoặc tiếp tục sử dụng các Permission `sale.*`.

---

# 3. LEAD → PROJECT

## 3.1. Lead là nguồn duy nhất của thông tin Khách hàng

**Không tạo bảng `customers`.**

Thông tin Khách hàng chỉ lưu tại `leads`, bao gồm tối thiểu:

- tên khách hàng
- điện thoại
- email
- Zalo
- địa chỉ khách hàng
- nguồn Lead
- nhu cầu khách hàng
- ghi chú chăm sóc
- trạng thái bán hàng

`projects` **không copy snapshot thông tin Customer**. Không có bảng hồ sơ `sales` riêng.

`projects.project_address` là **địa chỉ công trình**, khác với địa chỉ Khách hàng trong Lead.

## 3.2. Lead number

Mỗi Đối tác có số Lead tuần tự riêng.

Frontend không được tự làm `MAX + 1`; cần transaction/counter an toàn.

## 3.3. `leads.created_by`

`created_by` mặc định là User đang đăng nhập, nhưng có thể được gán theo nghiệp vụ nếu cần.

`activity_logs.actor_user_id` luôn giữ **người thực sự thực hiện thao tác**.

## 3.4. Workflow chăm sóc và phân công ngay trên Lead

1. Marketing kiếm data, hoặc khách tự đến; Marketing/Sales/người tiếp nhận có `lead.create` nhập tên, điện thoại và thông tin ban đầu để tạo Lead.
2. Người có `lead.assign` (thường là trưởng nhóm Sales) phân Lead cho các nhân viên chăm sóc.
3. Nhân viên được phân công bổ sung thông tin khách hàng, nhu cầu, ghi chú và trạng thái bán hàng **ngay trên Lead** bằng `lead.edit`, trong phạm vi được phép.

**Không tạo hồ sơ Sale riêng, kể cả bước tạo tự động ẩn phía sau.** Thông tin chăm sóc thuộc Lead; quan hệ Báo giá và Project đi trực tiếp từ Lead.

Trạng thái bán hàng trên Lead:

- Mới
- Đang chăm sóc
- Đã hẹn gặp
- Đã báo giá
- Thành công
- Thất bại

Thành công/Thất bại **có thể đổi lại**.

Một Lead có thể phân công cho **nhiều User**, không giới hạn hai người, không có người chính/phụ. Quan hệ phân công phải chống trùng cùng User trên cùng Lead và chống liên kết khác Partner. Tên bảng/cột thay thế `sale_users` sẽ được xác định đồng bộ khi sửa SQL; không tiếp tục giữ phụ thuộc vào hồ sơ Sale.

### Phạm vi xem Lead

| Tình trạng | Người được xem trong cùng Partner |
| --- | --- |
| Chưa có ai được phân công | User có quyền hiệu lực `lead.view.all` |
| Đã có người được phân công | User trong danh sách phụ trách có `lead.view`, hoặc User có `lead.view.all` |
| Owner/Admin | Xem mọi Lead, không phụ thuộc danh sách phụ trách |

- Trưởng nhóm muốn theo dõi cùng nhân viên phải tự thêm tên mình vào danh sách khi phân công.
- `lead.assign` không tự mở quyền xem mọi Lead đã giao cho người khác.
- Người tạo Lead/Marketing không giữ quyền xem sau phân công nếu không có trong danh sách phụ trách (trừ Owner/Admin).
- Bỏ hết người phụ trách thì chỉ người có `lead.view.all` (và Owner/Admin) xem được Lead.
- `lead.view` và `lead.view.all` là hai quyền độc lập, có thể cấp/thu hồi theo Role hoặc override từng User. `lead.view.all` chỉ mở phạm vi đọc trong cùng công ty; không tự cấp quyền sửa, xóa hoặc phân công.
- `lead.create` hoặc `lead.edit` không thay thế `lead.view`.
- Quyền sửa cần `lead.edit` và phạm vi Lead hợp lệ; quyền phân công cần `lead.assign` và phạm vi Lead hợp lệ. Khi thao tác phân công làm người thực hiện mất phạm vi, các lần truy cập sau phải áp dụng danh sách mới.
- Owner/Admin xem mọi dữ liệu trong Partner theo quyết định đã chốt; điều này không cho phép vượt tenant, trạng thái tài khoản/thuê bao hoặc các hành động quản trị được bảo vệ. Ngoại lệ xem toàn bộ của Owner/Admin phải được triển khai rõ, không suy diễn thành quyền ghi không giới hạn.

## 3.5. Tạo Project

Project **không tự sinh khi Lead chuyển Thành công**.

1. Trạng thái bán hàng của Lead được đánh dấu **Thành công**.
2. User có quyền và phạm vi phù hợp chủ động bấm **“Tạo Project”** trong Lead.
3. Có thể tạo nhiều Project từ cùng Lead.

Project lưu `source_lead_id`, cùng Partner với Lead nguồn; bỏ phụ thuộc `source_sale_id` và quan hệ Sale–Lead cũ.

## 3.6. Project number

Mỗi Partner có Project number tuần tự riêng: 01, 02, 03... trên UI.

Backend vẫn dùng UUID làm khóa chính.

## 3.7. Phạm vi module Project

Project có 4 cờ tùy chọn:

- `has_design`
- `has_purchasing`
- `has_production`
- `has_construction`

Chỉ module được chọn mới hiển thị.

**Nghiệm thu và Thanh toán luôn hiển thị** cho mọi Project.

## 3.8. Trạng thái Project

- Chưa bắt đầu
- Đang thực hiện
- Tạm dừng
- Hoàn thành
- Đã hủy

Có:

- tiến độ % nhập tay
- ngày bắt đầu
- deadline
- ngày hoàn thành
- main responsible
- tier S/M/L/VIP
- notes
- folder URL

## 3.9a. Ẩn Project — quyết định bổ sung đã chốt

- Không có chức năng xóa Project; bỏ Permission thông thường `project.delete`.
- Chỉ Owner/Admin được ẩn và bỏ ẩn Project, kiểm tra Role được bảo vệ; không cấp quyền này qua permission override.
- Project ẩn và dữ liệu thuộc Project chỉ Owner/Admin cùng Partner xem được; thành viên/Role khác không truy cập được cho đến khi bỏ ẩn.
- Bỏ ẩn khôi phục phạm vi/quyền bình thường, không đổi thành viên, dữ liệu, trạng thái hoặc lịch sử.
- Project ẩn vẫn tính đầy đủ vào quota. Ẩn/bỏ ẩn vẫn chịu kiểm tra tài khoản active, tenant và thuê bao cho phép ghi.
- Lead/Quote nguồn độc lập không bị ẩn theo Project. Inbox cá nhân vẫn self-only; thông báo gắn Project ẩn không được lộ cho User thường.

## 3.9. Project members và Project Sales

`project_members` = những User thuộc phạm vi Project.

`project_sales` = danh sách Sales của Project.

Khi tạo Project:

- Copy danh sách nhân viên Sales đang phụ trách Lead nguồn sang `project_sales`, giữ điều kiện hợp lệ của Project Sales bên dưới.
- Sau đó `project_sales` độc lập hoàn toàn với danh sách phụ trách Lead; thay đổi phân công Lead không tự sửa danh sách Sales của Project.

Nếu xóa Sales khỏi Project:

- Người đó không nhận thông báo mới của Project nữa.
- Lịch sử thông báo cũ vẫn giữ nguyên.

Project Sales phải là User active, cùng Partner và đáp ứng điều kiện bộ phận Sales theo quy tắc hệ thống.

---

# 4. PROJECT FINANCIALS

Thông tin tài chính tách khỏi `projects` thành `project_financials` để phân quyền riêng.

Permission:

- `financial.view`
- `financial.edit`

Hai quyền này độc lập với `project.view`.

Các trường chính:

- `budget`
- `contract_value`

Khi đổi phiên bản Báo giá đang áp dụng, **không tự động cập nhật `contract_value`**.

User có `financial.edit` phải điều chỉnh riêng nếu cần.

---

# 5. CATALOG

Không có bảng `project_items`.

Catalog là thư viện dùng chung riêng của từng Partner:

- `catalog_items`
- `catalog_item_materials`

Mỗi mẫu có:

- item code
- name
- category
- specifications
- dimensions
- unit
- coefficient
- notes
- `is_hidden`

Vật liệu có:

- material name
- base price
- selling price
- notes

Mẫu đã từng được dùng nên **ẩn (`is_hidden`) thay vì hard delete** để bảo toàn provenance.

Catalog chỉ được chọn trực tiếp trong:

- Quote
- Purchasing
- Production

**Không chọn Catalog trực tiếp trong Construction.**

Khi copy từ Catalog sang Quote/Purchasing/Production, dữ liệu đích là **snapshot độc lập**, chỉnh sửa hai bên không đồng bộ.

---

# 6. BÁO GIÁ — QUYẾT ĐỊNH QUAN TRỌNG

## 6.1. Cấu trúc

`quotes`
→ `quote_versions`
→ `quote_rooms`
→ `quote_groups`
→ `quote_items`
→ `quote_item_materials`

Một Lead có thể có nhiều Quote; tạo Báo giá trực tiếp từ Lead.

Một Quote có nhiều Version: V1, V2, V3...

## 6.2. Trạng thái phiên bản

- Nháp
- Đã gửi
- Đã chốt
- Đã hủy

Một Quote có thể có **nhiều phiên bản Đã chốt** cùng tồn tại.

## 6.3. Báo giá đã chốt là bất biến

Khi `quote_version` đã chốt:

- không sửa `quote_versions`
- không thêm/sửa/xóa `quote_rooms`
- không thêm/sửa/xóa `quote_groups`
- không thêm/sửa/xóa `quote_items`
- không thêm/sửa/xóa `quote_item_materials`

Muốn thay đổi → tạo version mới.

## 6.4. V1 → V2

Khi clone version:

- tạo ID mới cho toàn bộ room/group/item/material.
- giữ `quote_items.lineage_id` để nhận biết cùng một hạng mục qua các Version.
- material ID phải được map lại đúng sang bản clone.
- `finalized_material_id` của item phải trỏ tới material mới tương ứng, không được giữ ID material của Version cũ.

## 6.5. Công thức quantity

- `cái`, `bộ` → quantity = count
- `md` → length × count
- `m²` → length × height × count
- `m³` → length × width × height × count
- đơn vị khác → nhập manual

Có `quantity_mode = auto/manual`.

Tiền VND dùng half-up rounding.

VAT lưu dạng free text.

## 6.6. Nhiều phương án vật liệu

`quote_item_materials` là **các vật liệu thay thế nhau**, không phải các thành phần cộng dồn.

`is_selected` có thể có 0 / 1 / nhiều material để hiển thị so sánh.

`quote_items.finalized_material_id` là **một material cuối cùng duy nhất**, nếu đã quyết định.

### Quyết định rất quan trọng

**ĐƯỢC PHÉP CHỐT Quote dù một số item vẫn còn nhiều phương án vật liệu chưa xác định cuối cùng.**

Nếu chưa đủ cơ sở xác định tổng tiền chính thức:

- `quote_versions.total_amount = NULL`
- UI hiển thị **TẠM TÍNH**
- Không cộng các vật liệu thay thế lại với nhau
- Không dùng `0` để giả vờ là tổng tiền

## 6.7. Quote và Customer

Quote chỉ lưu `lead_id` và thông tin báo giá; bỏ `sale_id`.

Không copy tên/điện thoại/địa chỉ Customer vào Quote.

Thông tin Customer khi xem/xuất Quote được join từ Lead.

---

# 7. PROJECT ↔ QUOTE VERSION

## 7.1. Phiên bản hiện hành

`projects.current_quote_version_id` là Version đang áp dụng hiện tại cho Project.

Nó phải:

- cùng Partner
- thuộc Lead nguồn của Project
- ở trạng thái **Đã chốt**

Nếu Project dùng Báo giá Excel bên ngoài thì `current_quote_version_id` có thể NULL.

## 7.2. Lịch sử áp dụng

Dùng `project_quote_history`:

- `project_id`
- `quote_version_id`
- `applied_at`
- `applied_by`
- `replaced_at`
- `replaced_by`
- notes

Chỉ có một record active (`replaced_at IS NULL`) trên mỗi Project khi đang áp dụng Quote nội bộ.

## 7.3. Được phép áp dụng lại Version cũ

**ĐÃ CHỐT:** có thể trực tiếp áp dụng lại V1, không bắt buộc tạo V3.

Ví dụ hợp lệ:

V1 → V2 → V1

Lịch sử phải có 3 record riêng.

Vì vậy **không được UNIQUE `(project_id, quote_version_id)`**.

Chỉ tạo partial unique:

`UNIQUE(company_id, project_id) WHERE replaced_at IS NULL`

## 7.4. Áp dụng Version mới không làm thay đổi dữ liệu module đã copy

Khi Project đổi V1 → V2:

- không tự sửa Purchasing items
- không tự sửa Production items
- không tự sửa Construction items
- không tự sửa `project_financials.contract_value`

Mọi dữ liệu đã copy là snapshot độc lập.

---

# 8. NGUỒN HẠNG MỤC Ở PURCHASING / PRODUCTION / CONSTRUCTION

## Purchasing

Có thể tạo item từ:

- Quote item
- Catalog item
- Manual

## Production

Có thể tạo item từ:

- Quote item
- Catalog item
- Manual

## Construction

Có thể tạo item từ:

- Quote item
- Manual

**Không có Catalog direct source ở Construction.**

## Quy tắc source

- Nếu manual → cả source NULL.
- Nếu lấy Quote → `source_quote_item_id` có giá trị, Catalog source NULL.
- Nếu lấy Catalog → `source_catalog_item_id` có giá trị, Quote source NULL.

### Quote item nào được phép làm nguồn?

Quote item phải thuộc **một phiên bản Đã chốt từng được áp dụng hợp lệ cho chính Project đó trong lịch sử**.

Không bắt buộc phải thuộc Version đang current.

Ví dụ Project từng áp dụng V1, sau đó chuyển V2: item đã copy từ V1 vẫn hợp lệ.

---

# 9. MODULE THIẾT KẾ

`project_designs`, `design_users`, `design_rounds`.

Trạng thái tổng:

- Chưa bắt đầu
- Đang thiết kế
- Chờ khách duyệt
- Đã duyệt
- Đã hủy

Nhiều Designer phụ trách ngang quyền.

Round status:

- Đã gửi
- Đang sửa
- Sửa xong
- Đã duyệt
- Đã hủy

Khi tạo/gửi round mới, round trước đang Đang sửa → Sửa xong.

Lần gửi mới nhất ở trạng thái Đã gửi → trạng thái tổng Thiết kế = Chờ khách duyệt. Khi khách yêu cầu sửa, chuyển lần gửi đó sang Đang sửa → trạng thái tổng = Đang thiết kế. Sửa xong vẫn là Đang thiết kế cho đến khi gửi một lần mới. Lần gửi mới nhất Đã duyệt → trạng thái tổng = Đã duyệt. Thay đổi ở lần gửi cũ không ghi đè trạng thái tổng của lần gửi mới nhất.

`Đã hủy` của **lần gửi** và `Đã hủy` của **toàn bộ Thiết kế** là hai trạng thái độc lập. Hủy một lần gửi không tự hủy toàn bộ Thiết kế. Khi quyết định hủy toàn bộ, User có quyền sửa Thiết kế tự chuyển trạng thái tổng sang `Đã hủy`; thao tác ở lần gửi không được tự mở lại Thiết kế đã hủy. Việc hủy Thiết kế không tự hủy Project.

---

# 10. MODULE MUA HÀNG

`project_purchasing`, `purchasing_users`, `purchasing_items`, `purchasing_receipts`.

Item status:

- Chưa đặt
- Đã đặt
- Đang vận chuyển
- Đã nhận

Mỗi receipt có ngày + quantity.

Nếu tổng nhận >= required quantity → tự động `Đã nhận`.

Nếu sau đó sửa/xóa receipt khiến tổng nhận < required:

- phải phục hồi trạng thái nghiệp vụ phù hợp trước đó
- **không được mặc định đoán thành `Đang vận chuyển`**

Hàng hỏng/thay thế: giảm batch cũ và thêm batch thay thế; không tăng `required_quantity` chỉ để bù hàng hỏng.

Trạng thái tổng Mua hàng:

- Chưa đặt: empty hoặc tất cả item Chưa đặt
- Đã xong: có item và tất cả Đã nhận
- Đang mua: các trường hợp khác

---

# 11. MODULE SẢN XUẤT

`project_production`, `production_users`, `production_items`, `production_batches`.

Item status:

- Chưa sản xuất
- Đang sản xuất
- Hoàn thành

`actual_cost` nhập thủ công trên từng production item.

Nếu sum(batch quantity) >= required → Hoàn thành.

Nếu sửa batch làm tổng giảm xuống dưới required → phải revert trạng thái phù hợp.

Trạng thái tổng:

- Chưa sản xuất
- Đang sản xuất
- Đã xong

---

# 12. MODULE THI CÔNG

`project_construction`, `construction_users`, `construction_items`, `construction_batches`, `construction_expense_categories`, `construction_expenses`.

Site address ban đầu copy từ `projects.project_address`, sau đó độc lập.

Item status:

- Chưa thi công
- Đang thi công
- Hoàn thành

Construction cost **không nhập tay**.

Chi phí thực tế = `SUM(construction_expenses.amount)`.

Nhóm chi phí mặc định:

- Nhân công
- Vật tư
- Vận chuyển
- Máy móc
- Thuê ngoài
- Khác

Partner có thể tùy chỉnh/ẩn nhóm.

---

# 13. NGHIỆM THU

Nghiệm thu là **cấp Project**, không phụ thuộc Project có module Thi công hay không.

Bảng:

- `project_acceptance`
- `acceptance_users`
- `acceptance_rounds`

Trạng thái tổng:

- Chưa nghiệm thu
- Đang nghiệm thu
- Cần khắc phục
- Đã nghiệm thu

Round result:

- Đạt
- Cần khắc phục

**Chỉ round mới nhất quyết định trạng thái tổng.**

## Đồng bộ Project

Nếu round mới nhất = Đạt:

- acceptance = Đã nghiệm thu
- Project → Hoàn thành
- `completed_date` = ngày round
- lưu `completion_source_acceptance_round_id`

Nếu round mới nhất đổi lại thành Cần khắc phục:

- acceptance = Cần khắc phục
- Project → Đang thực hiện
- chỉ xóa `completed_date` nếu ngày hoàn thành đó được tự sinh bởi chính round đã bị đảo kết quả

Không ép `progress_percent = 100`.

Không tự ép các module khác thành hoàn thành.

**Không auto override Project nếu Project đang `Tạm dừng` hoặc `Đã hủy`.**

`acceptance.assign` chỉ được gán người đã là Project member.

Muốn thêm người mới vào Project trước → cần `project.manage_members`.

---

# 14. THANH TOÁN

`project_payments`.

Trên UI chỉ nhập:

- `transfer_at`
- `amount`

STT được tính tự động theo thứ tự hiển thị, không cần nhập tay.

Tổng đã thanh toán = SUM(payments).

Còn lại và % thanh toán được tính từ `project_financials.contract_value` + payments.

Thanh toán độc lập với trạng thái hoàn thành Project.

---

# 15. TÀI LIỆU & STORAGE

- File nhỏ → Cloudflare R2.
- File lớn → link Google Drive / OneDrive / Dropbox do Partner tự quản lý.
- MVP không làm OAuth/API/sync với các dịch vụ ngoài.
- Không có Customer Portal.

Database chỉ lưu metadata / object key / URL.

Không lưu signed URL R2 lâu dài trong DB.

---

# 16. THÔNG BÁO

Chuông thông báo:

- góc trên bên phải
- hiển thị 5 thông báo mới nhất
- cuộn tối đa 100
- unread màu đen `#000`, chấm xanh `#0866FF`
- read màu xám `#717171`
- hỗ trợ toggle read/unread và Mark all

`users.notification_sound_enabled`.

Âm thanh chỉ phát khi có thông báo realtime mới, không phát lại khi reload.

## Người nhận thông báo quá hạn

Tùy module nhưng tổng quát gồm:

- người được giao module
- CURRENT `project_sales`
- Giám sát là Project member
- Owner/Admin

Removed Sales không nhận thông báo mới, nhưng lịch sử cũ vẫn giữ.

Không gửi cho User disabled.

Thông báo quá hạn phải dedup theo:

- company
- module/entity
- `deadline_revision`

A → B → A vẫn là sự kiện deadline mới nếu revision tăng.

---

# 17. ACTIVITY LOG

`activity_logs` append-only.

Các trường chính:

- company_id
- actor_user_id (NULL nếu system)
- action
- entity_type
- entity_id
- project_id
- `old_data JSONB`
- `new_data JSONB`
- created_at

Không dùng lại trường `changes` của các draft cũ.

Không ghi secrets, token, signed URL hoặc mật khẩu.

---

# 18. SUBSCRIPTION / PLAN

Thuê bao năm.

## Starter

- 6.8 triệu VND/năm
- 20 active Users
- 200 Projects
- 20 GiB R2
- grace 7 ngày

## Business

- 16.8 triệu VND/năm
- 100 Users
- 1000 Projects
- 100 GiB R2
- grace 1 tháng lịch
- OneDrive ngoài hệ thống 1000 GB

## Enterprise

- 36.8 triệu VND/năm
- 10,000 Users
- 10,000 Projects
- 1000 GiB R2
- grace 1 năm lịch
- OneDrive ngoài hệ thống 1000 GB

**Tất cả module có ở mọi tier.**

Hết hạn:

1. Trong grace → read-only + export.
2. Hết grace → khóa truy cập dữ liệu.
3. **Không tự xóa dữ liệu.**
4. Gia hạn → truy cập trở lại.

Quota check phải atomic.

Không naïve chọn subscription bằng “expiry mới nhất”; phải xác định đúng active period.

---

# 19. RLS / SECURITY NGUYÊN TẮC

- Supabase Auth + PostgreSQL RLS.
- Mọi dữ liệu business tenant-scoped bằng `company_id`.
- Composite FK ở các quan hệ cần chống cross-tenant.
- RLS phải dùng Permission hiệu lực: User override trước, Role sau.
- Permission không tự động bỏ qua Project scope.
- Frontend không được trực tiếp sửa `role_permissions` / `user_permissions` nếu thao tác cần protected logic; nên đi qua RPC.
- `SECURITY DEFINER` phải có `SET search_path = ''` hoặc search_path an toàn và revoke EXECUTE khỏi PUBLIC nếu là hàm nội bộ.
- Các hành động đặc biệt Owner/Admin cần kiểm tra độc lập, không chỉ dựa trên `has_permission()`.

---

# 20. TRẠNG THÁI MIGRATION HIỆN TẠI

Đã có các bản nháp SQL 001–010:

| Migration | Nội dung hiện tại |
| --- | --- |
| 001 | Foundation / Company / User / Role / Permission / Subscription |
| 002 | Lead / Sale / Project — còn thiết kế Sale cũ, cần sửa |
| 003 | Catalog / Quote |
| 004 | Project Modules |
| 005 | Acceptance / Payment / Documents / Notifications / Activity Logs |
| 006 | Cross-table FKs & constraints |
| 007 | Functions / RPCs |
| 008 | Triggers |
| 009 | RLS |
| 010 | Seeds / default roles / permissions / categories |

**Tài liệu đã cập nhật quyết định mới; SQL 001–010 chưa được sửa theo các quyết định ngày 24/09/2026.** Migration 010 hiện còn seed 61 mã cũ và chưa có đầy đủ ma trận Role vừa chốt.

Việc tiếp theo khi được yêu cầu sửa SQL:

1. Sửa trực tiếp bộ migration nháp gốc để hợp nhất chăm sóc vào Lead, bỏ hồ sơ Sale và bốn quyền `sale.*`.
2. Rà soát tất cả bảng/cột, FK, UNIQUE, quan hệ phân công, nguồn Báo giá/Project, lịch sử áp dụng, RPC, trigger, RLS và seed có liên quan.
3. Giữ lịch sử V1 → V2 → V1, snapshot module và các quyết định khác không liên quan.
4. Cập nhật README, giải thích thay đổi và đóng ZIP đầy đủ.
5. Sau đó thiết lập Supabase Local, chạy từ DB trống và kiểm thử compile/runtime, RLS, override allow/deny, tenant isolation và phân công Lead.

Chưa chạy PostgreSQL/Supabase Local; chưa xác nhận compile hoặc production-ready. Không cần tạo Migration 011 chỉ để vá thiết kế cũ khi bộ 001–010 vẫn chưa triển khai.

---

# 21. CÁC HẠNG MỤC KHÔNG LÀM TRONG MVP

- Customer Portal
- Đồng bộ Google Drive/OneDrive/Dropbox bằng OAuth/API
- Gantt dependency nâng cao
- Inventory hoàn chỉnh
- Subcontractor management nâng cao
- Advanced accounting
- Nghiệm thu theo staged volume phức tạp

---

# 22. HƯỚNG DẪN CHO CHAT MỚI

1. Đọc tài liệu này trước; đây là nguồn yêu cầu chính.
2. Đọc bộ Migration 001–010 và README hiện có.
3. Ưu tiên workflow Lead và ma trận quyền ngày 24/09/2026 trong tài liệu này so với SQL cũ.
4. Không khôi phục hồ sơ Sale riêng hoặc tự thay đổi các quyết định khác.
5. Khi được yêu cầu cập nhật SQL, sửa đồng bộ migration gốc và kiểm toán tên bảng/cột/FK/UNIQUE, Functions, Triggers, RLS, Seeds.
6. Chỉ chạy PostgreSQL/Supabase Local ở bước kiểm thử được yêu cầu; không tuyên bố đã kiểm thử khi chưa thực hiện.

## Câu mở đầu gợi ý cho chat mới

> Tiếp tục cập nhật bộ Migration 001–010 theo project_handoff_business_decisions.md đã chốt ngày 24/09/2026. Workflow chăm sóc nằm hoàn toàn trên Lead, không có hồ sơ Sale riêng; Lead có nhiều người phụ trách và phạm vi xem thay đổi theo phân công. Áp dụng ma trận Role trong tài liệu, kiểm toán và sửa đồng bộ SQL gốc, cập nhật README và đóng ZIP. Bộ SQL hiện chưa được kiểm thử PostgreSQL/Supabase Local.

---

**END OF HANDOFF DOCUMENT**
# Bổ sung nghiệp vụ Lead và Project — 26/09/2026

Các quyết định mới nhất của người dùng cho Build Flow:

- `source_2` và `source_3` mô tả sâu hơn nguồn Lead. Ví dụ `source=Facebook`, `source_2=Bài quảng cáo A`, `source_3=ID bài quảng cáo`. Hai trường chi tiết là văn bản tự nhập.
- Trường liên hệ `leads.zalo` hiển thị trên Lead với nhãn “Zalo / Facebook”, cho nhập văn bản tùy ý; không ép định dạng số điện thoại hoặc URL.
- Loại thực hiện là chọn nhiều, lưu độc lập ở Lead và Project. Khi tạo Project từ Lead thành công, Project nhận bản sao loại thực hiện và loại công trình; sửa Lead về sau không sửa Project. Các lựa chọn khởi tạo: Xây dựng, Thiết kế, Thi công. Cờ module Project (`has_design` v.v.) vẫn là phạm vi module và không bị thay thế bởi loại thực hiện.
- Loại công trình là lựa chọn một giá trị, lưu ở Lead và Project. Các lựa chọn khởi tạo: Nhà đất, Chung cư, Nhà hàng, Khách sạn; đối tác tự bổ sung.
- Quyết định ngân sách mới nhất thay thế bản dự kiến/thực tế: Lead chỉ có `leads.budget`, Project chỉ có `project_financials.budget`. Sale và Marketing tự nhập một giá trị ở từng nơi. Hai giá trị độc lập, không tự đồng bộ hoặc tổng hợp từ chi phí; `contract_value` giữ nguyên.
- Trạng thái Sale vẫn dùng `leads.status` với sáu giá trị đã chốt; không tạo bảng Sale. Lead ở trạng thái Thất bại bắt buộc có lý do thất bại được chọn từ danh mục của cùng công ty. Có thể đổi lại trạng thái Thành công/Thất bại. Lý do cũ còn lưu khi đổi lại trạng thái để giữ ngữ cảnh; UI chỉ yêu cầu khi chọn Thất bại.
- Các trường dạng lựa chọn (Nguồn, Loại thực hiện, Loại công trình, Lý do thất bại) có nút ＋ cuối danh sách để tạo lựa chọn và × để bỏ lựa chọn. Bỏ là ẩn khỏi danh sách mới, không xóa dữ liệu cũ; thêm lại cùng tên sẽ kích hoạt lại. Danh mục riêng theo company_id, có kiểm tra quyền hiệu lực, tenant và thuê bao trước ghi.

Thực thi bằng migration 011, giữ 001–010 nguyên nội dung. Script sync/check nâng số migration từ 10 lên 11. RLS và RPC xác định phạm vi từ JWT người dùng thật. Dữ liệu đang có giữ nguyên, không backfill tùy tiện giá trị phân loại/ngân sách/lý do.
